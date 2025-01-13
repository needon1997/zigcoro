const std = @import("std");
const libcoro = @import("libcoro");
const xev = @import("xev");
const aio = libcoro.asyncio;

threadlocal var env: struct { allocator: std.mem.Allocator, exec: *aio.Executor } = undefined;

const AioTest = struct {
    allocator: std.mem.Allocator,
    tp: *xev.ThreadPool,
    loop: *xev.Loop,
    exec: *aio.Executor,
    stacks: []u8,

    fn init() !@This() {
        const allocator = std.testing.allocator;

        // Allocate on heap for pointer stability
        var tp = try allocator.create(xev.ThreadPool);
        var loop = try allocator.create(xev.Loop);
        var exec = try allocator.create(aio.Executor);
        _ = &tp;
        _ = &loop;
        _ = &exec;
        tp.* = xev.ThreadPool.init(.{});
        loop.* = try xev.Loop.init(.{ .thread_pool = tp });
        exec.* = aio.Executor.init(loop);
        const stack_size = 1024 * 128;
        const num_stacks = 5;
        const stacks = try allocator.alignedAlloc(u8, libcoro.stack_alignment, num_stacks * stack_size);

        // Thread-local env
        env = .{
            .allocator = allocator,
            .exec = exec,
        };

        aio.initEnv(.{
            .executor = exec,
            .stack_allocator = allocator,
            .default_stack_size = stack_size,
        });

        return .{
            .allocator = allocator,
            .tp = tp,
            .loop = loop,
            .exec = exec,
            .stacks = stacks,
        };
    }

    fn deinit(self: @This()) void {
        self.loop.deinit();
        self.tp.shutdown();
        self.tp.deinit();
        self.allocator.destroy(self.tp);
        self.allocator.destroy(self.loop);
        self.allocator.destroy(self.exec);
        self.allocator.free(self.stacks);
    }

    fn run(self: @This(), func: anytype) !void {
        const stack = try libcoro.stackAlloc(self.allocator, 1024 * 32);
        defer self.allocator.free(stack);
        try aio.run(self.exec, func, .{}, stack);
    }
};

test "aio sleep top-level" {
    const t = try AioTest.init();
    defer t.deinit();
    try aio.sleep(t.exec, 10);
}

fn sleep(ms: u64) !i64 {
    try aio.sleep(env.exec, ms);
    try std.testing.expect(libcoro.remainingStackSize() > 1024 * 2);
    return std.time.milliTimestamp();
}

test "aio sleep run" {
    const t = try AioTest.init();
    defer t.deinit();

    const stack = try libcoro.stackAlloc(
        t.allocator,
        null,
    );
    defer t.allocator.free(stack);
    const before = std.time.milliTimestamp();
    const after = try aio.run(t.exec, sleep, .{10}, stack);

    try std.testing.expect(after > (before + 7));
    try std.testing.expect(after < (before + 13));
}

fn sleepTask() !void {
    const stack = try libcoro.stackAlloc(
        env.allocator,
        null,
    );
    defer env.allocator.free(stack);
    const sleep1 = try aio.xasync(sleep, .{10}, stack);

    const stack2 = try libcoro.stackAlloc(
        env.allocator,
        null,
    );
    defer env.allocator.free(stack2);
    const sleep2 = try aio.xasync(sleep, .{20}, stack2);

    const after = try aio.xawait(sleep1);
    const after2 = try aio.xawait(sleep2);

    try std.testing.expect(after2 > (after + 7));
    try std.testing.expect(after2 < (after + 13));
}

test "aio concurrent sleep" {
    const t = try AioTest.init();
    defer t.deinit();

    const stack = try libcoro.stackAlloc(
        t.allocator,
        1024 * 8,
    );
    defer t.allocator.free(stack);
    const before = std.time.milliTimestamp();
    try aio.run(t.exec, sleepTask, .{}, stack);
    const after = std.time.milliTimestamp();

    try std.testing.expect(after > (before + 17));
    try std.testing.expect(after < (before + 23));
}

const TickState = struct {
    slow: usize = 0,
    fast: usize = 0,
};

fn tickLoop(tick: usize, state: *TickState) !void {
    const amfast = tick == 10;
    for (0..10) |i| {
        try aio.sleep(env.exec, tick);
        if (amfast) {
            state.fast += 1;
        } else {
            state.slow += 1;
        }
        if (!amfast and i >= 6) {
            try std.testing.expectEqual(state.fast, 10);
        }
    }
}

fn aioTimersMain() !void {
    const stack_size: usize = 1024 * 16;

    var tick_state = TickState{};

    // 2 parallel timer loops, one fast, one slow
    const stack1 = try libcoro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(stack1);
    const co1 = try aio.xasync(tickLoop, .{ 10, &tick_state }, stack1);
    const stack2 = try libcoro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(stack2);
    const co2 = try aio.xasync(tickLoop, .{ 20, &tick_state }, stack2);

    try aio.xawait(co1);
    try aio.xawait(co2);
}

test "aio timers" {
    const t = try AioTest.init();
    defer t.deinit();
    try t.run(aioTimersMain);
}

fn tcpMain() !void {
    const stack_size = 1024 * 32;

    var info: ServerInfo = .{};

    var server = try aio.xasync(tcpServer, .{&info}, stack_size);
    defer server.deinit();

    var client = try aio.xasync(tcpClient, .{&info}, stack_size);
    defer client.deinit();

    try aio.xawait(server);
    try aio.xawait(client);
}

test "aio tcp" {
    const t = try AioTest.init();
    defer t.deinit();
    try t.run(tcpMain);
}

fn fileRW() !void {
    const path = "test_watcher_file";
    const f = try std.fs.cwd().createFile(path, .{
        .read = true,
        .truncate = true,
    });
    defer f.close();
    defer std.fs.cwd().deleteFile(path) catch {};
    const xfile = try xev.File.init(f);
    const file = aio.File.init(env.exec, xfile);
    var write_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    const write_len = try file.write(&write_buf);
    try std.testing.expectEqual(write_len, write_buf.len);
    try f.sync();
    const f2 = try std.fs.cwd().openFile(path, .{});
    defer f2.close();
    const xfile2 = try xev.File.init(f2);
    const file2 = aio.File.init(env.exec, xfile2);
    var read_buf: [128]u8 = undefined;
    const read_len = try file2.read(&read_buf);
    try std.testing.expectEqual(write_len, read_len);
    try std.testing.expect(std.mem.eql(u8, &write_buf, read_buf[0..read_len]));
}

test "aio file" {
    const t = try AioTest.init();
    defer t.deinit();
    try t.run(fileRW);
}

fn udpMain() !void {
    const stack_size = 1024 * 32;
    var info: ServerInfo = .{};

    const stack1 = try libcoro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(stack1);
    const server_co = try aio.xasync(udpServer, .{&info}, stack1);

    const stack2 = try libcoro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(stack2);
    const client_co = try aio.xasync(udpClient, .{&info}, stack2);

    try aio.xawait(server_co);
    try aio.xawait(client_co);
}

test "aio udp" {
    const t = try AioTest.init();
    defer t.deinit();
    try t.run(udpMain);
}

fn processTest() !void {
    const alloc = std.heap.c_allocator;
    var child = std.process.Child.init(&.{ "sh", "-c", "exit 0" }, alloc);
    try child.spawn();

    var xp = try xev.Process.init(child.id);
    defer xp.deinit();

    const p = aio.Process.init(env.exec, xp);
    const rc = try p.wait();
    try std.testing.expectEqual(rc, 0);
}

test "aio process" {
    const t = try AioTest.init();
    defer t.deinit();
    try t.run(processTest);
}

fn asyncMain() !void {
    const stack_size = 1024 * 32;
    var nstate = NotifierState{ .x = try xev.Async.init() };

    const stack = try libcoro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(stack);
    const co = try aio.xasync(asyncTest, .{&nstate}, stack);

    const stack2 = try libcoro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(stack2);
    const nco = try aio.xasync(asyncNotifier, .{&nstate}, stack2);

    try aio.xawait(co);
    try aio.xawait(nco);
}

test "aio async" {
    const t = try AioTest.init();
    defer t.deinit();
    try t.run(asyncMain);
}

const ServerInfo = struct {
    addr: std.net.Address = undefined,
};

fn tcpServer(info: *ServerInfo) !void {
    var address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const xserver = try xev.TCP.init(address);

    try xserver.bind(address);
    try xserver.listen(1);

    var sock_len = address.getOsSockLen();
    try std.posix.getsockname(xserver.fd, &address.any, &sock_len);
    info.addr = address;

    const server = aio.TCP.init(env.exec, xserver);
    const conn = try server.accept();
    defer conn.close() catch unreachable;
    try server.close();

    var recv_buf: [128]u8 = undefined;
    const recv_len = try conn.read(&recv_buf);
    const send_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    try std.testing.expect(std.mem.eql(u8, &send_buf, recv_buf[0..recv_len]));
}

fn tcpClient(info: *ServerInfo) !void {
    const address = info.addr;
    const xclient = try xev.TCP.init(address);
    const client = aio.TCP.init(env.exec, xclient);
    defer client.close() catch unreachable;
    _ = try client.connect(address);
    var send_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    const send_len = try client.write(&send_buf);
    try std.testing.expectEqual(send_len, 7);
}

fn udpServer(info: *ServerInfo) !void {
    var address = try std.net.Address.parseIp4("127.0.0.1", 0);
    const xserver = try xev.UDP.init(address);

    try xserver.bind(address);

    var sock_len = address.getOsSockLen();
    try std.posix.getsockname(xserver.fd, &address.any, &sock_len);
    info.addr = address;

    const server = aio.UDP.init(env.exec, xserver);

    var recv_buf: [128]u8 = undefined;
    const recv_len = try server.read(.{ .slice = &recv_buf });
    var send_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    try std.testing.expectEqual(recv_len, send_buf.len);
    try std.testing.expect(std.mem.eql(u8, &send_buf, recv_buf[0..recv_len]));
    try server.close();
}

fn udpClient(info: *ServerInfo) !void {
    const xclient = try xev.UDP.init(info.addr);
    const client = aio.UDP.init(env.exec, xclient);
    var send_buf = [_]u8{ 1, 1, 2, 3, 5, 8, 13 };
    const send_len = try client.write(info.addr, .{ .slice = &send_buf });
    try std.testing.expectEqual(send_len, 7);
    try client.close();
}

const NotifierState = struct {
    x: xev.Async,
    notified: bool = false,
};

fn asyncTest(state: *NotifierState) !void {
    const notif = aio.AsyncNotification.init(env.exec, state.x);
    try notif.wait();
    state.notified = true;
}

fn asyncNotifier(state: *NotifierState) !void {
    try state.x.notify();
    try aio.sleep(env.exec, 10);
    try std.testing.expect(state.notified);
}

test "aio sleep env" {
    const t = try AioTest.init();
    defer t.deinit();

    const before = std.time.milliTimestamp();
    const after = try aio.run(null, sleep, .{10}, null);

    try std.testing.expect(after > (before + 7));
    try std.testing.expect(after < (before + 13));
}

fn sleepTaskEnv() !void {
    var sleep1 = try aio.xasync(sleep, .{10}, null);
    defer sleep1.deinit();
    var sleep2 = try aio.xasync(sleep, .{20}, null);
    defer sleep2.deinit();

    const after = try aio.xawait(sleep1);
    const after2 = try aio.xawait(sleep2);

    try std.testing.expect(after2 > (after + 7));
    try std.testing.expect(after2 < (after + 13));
}

test "aio concurrent sleep env" {
    const t = try AioTest.init();
    defer t.deinit();

    const before = std.time.milliTimestamp();
    try aio.run(null, sleepTaskEnv, .{}, null);
    const after = std.time.milliTimestamp();

    try std.testing.expect(after > (before + 17));
    try std.testing.expect(after < (before + 23));
}

const UsizeChannel = libcoro.Channel(usize, libcoro.ChannelConfig{ .sized = 10 });

fn sender(chan: *UsizeChannel, count: usize) !void {
    defer chan.close();
    for (0..count) |i| {
        try chan.send(i);
        try aio.sleep(null, 10);
    }
}

fn recvr(chan: *UsizeChannel) usize {
    var sum: usize = 0;
    while (chan.recv()) |val| sum += val;
    return sum;
}

fn chanMain() !usize {
    var chan = UsizeChannel.init(null);
    const send_frame = try libcoro.xasync(sender, .{ &chan, 6 }, null);
    defer send_frame.deinit();
    const recv_frame = try libcoro.xasync(recvr, .{&chan}, null);
    defer recv_frame.deinit();

    try libcoro.xawait(send_frame);
    return libcoro.xawait(recv_frame);
}

test "aio mix channels" {
    const t = try AioTest.init();
    defer t.deinit();

    const sum = try aio.run(null, chanMain, .{}, null);
    try std.testing.expectEqual(sum, 15);
}

const TaskState = struct { called: bool = false };

fn notifyAfterBlockingSleep(notifcation: *aio.AsyncNotification, state: *NotifierState) void {
    std.time.sleep(20 * std.time.ns_per_ms);
    notifcation.notif.notify() catch unreachable;
    state.notified = true;
}

fn asyncRecurseSleepAndNotification() !void {
    const pool: *std.Thread.Pool = try env.allocator.create(std.Thread.Pool);
    defer env.allocator.destroy(pool);

    try std.Thread.Pool.init(pool, .{ .allocator = env.allocator });
    defer pool.deinit();

    var nstate = NotifierState{ .x = try xev.Async.init() };
    var tstate = TaskState{};

    var notification = aio.AsyncNotification.init(env.exec, nstate.x);
    defer notification.notif.deinit();

    const asyncTaskDoingAsyncSleep = try aio.xasync(struct {
        fn call(exec: *aio.Executor, state: *TaskState) !void {
            try aio.sleep(exec, 1);
            state.called = true;
        }
    }.call, .{ env.exec, &tstate }, null);
    defer asyncTaskDoingAsyncSleep.deinit();

    try pool.spawn(notifyAfterBlockingSleep, .{ &notification, &nstate });

    try notification.wait();
    try libcoro.xawait(asyncTaskDoingAsyncSleep);

    try std.testing.expect(nstate.notified);
    try std.testing.expect(tstate.called);
}

test "aio mix async recurse in sleep and notification" {
    const t = try AioTest.init();
    defer t.deinit();

    try t.run(asyncRecurseSleepAndNotification);
}

fn add(x: u32, y: u32) u32 {
    std.debug.print("add\n", .{});

    return x +| y;
}

fn sub(x: u32, y: u32) u32 {
    std.debug.print("sub\n", .{});

    return x -| y;
}

fn report_add(sum: u32) void {
    std.debug.print("{}\n", .{sum});
}

fn report_sub(sum: u32) void {
    std.debug.print("{}\n", .{sum});
}

fn selecMain() !void {
    const stack_size: usize = 1024 * 16;
    const stack1 = try libcoro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(stack1);
    const stack2 = try libcoro.stackAlloc(env.allocator, stack_size);
    defer env.allocator.free(stack2);
    try aio.xselect(.{ .{ add, .{ @as(u32, 1), @as(u32, 2) }, report_add, stack1 }, .{ sub, .{ @as(u32, 1), @as(u32, 1) }, report_sub, stack2 } });
}

test "select" {
    const t = try AioTest.init();
    defer t.deinit();

    aio.run(null, selecMain, .{}, null) catch |err| {
        std.debug.print("{}", .{err});
    };
}
