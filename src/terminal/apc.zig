const std = @import("std");
const build_options = @import("terminal_options");
const Allocator = std.mem.Allocator;

const kitty_gfx = @import("kitty/graphics.zig");

const log = std.log.scoped(.terminal_apc);

/// APC command handler. This should be hooked into a terminal.Stream handler.
/// The start/feed/end functions are meant to be called from the terminal.Stream
/// apcStart, apcPut, and apcEnd functions, respectively.
pub const Handler = struct {
    state: State = .inactive,

    /// Maximum bytes each APC protocol can buffer. This is to prevent
    /// malicious input from causing us to allocate too much memory.
    /// If you want to be lazy and set a single value for all protocols,
    /// use `.initFull`.
    max_bytes: std.EnumMap(Protocol, usize) = .initFullWith(.{
        .kitty = Protocol.defaultMaxBytes(.kitty),
    }),

    pub fn deinit(self: *Handler) void {
        self.state.deinit();
    }

    pub fn start(self: *Handler) void {
        self.state.deinit();
        self.state = .{ .identify = {} };
    }

    pub fn feed(self: *Handler, alloc: Allocator, byte: u8) void {
        switch (self.state) {
            .inactive => unreachable,

            // We're ignoring this APC command, likely because we don't
            // recognize it so there is no need to store the data in memory.
            .ignore => return,

            // We identify the APC command by the first byte.
            .identify => {
                switch (byte) {
                    // Kitty graphics protocol
                    'G' => self.state = if (comptime build_options.kitty_graphics)
                        .{ .kitty = .init(
                            alloc,
                            self.max_bytes.get(.kitty) orelse
                                Protocol.defaultMaxBytes(.kitty),
                        ) }
                    else
                        .ignore,

                    // Unknown
                    else => self.state = .ignore,
                }
            },

            .kitty => |*p| if (comptime build_options.kitty_graphics) {
                p.feed(byte) catch |err| {
                    log.warn("kitty graphics protocol error: {}", .{err});
                    p.deinit();
                    self.state = .ignore;
                };
            } else unreachable,
        }
    }

    pub fn feedSlice(self: *Handler, alloc: Allocator, slice: []const u8) usize {
        switch (self.state) {
            .inactive => unreachable,
            .ignore => return slice.len,
            .identify => {
                if (slice.len == 0) return 0;
                self.feed(alloc, slice[0]);
                return 1;
            },
            .kitty => |*p| if (comptime build_options.kitty_graphics) {
                return p.feedSlice(slice) catch |err| {
                    log.warn("kitty graphics protocol error: {}", .{err});
                    p.deinit();
                    self.state = .ignore;
                    return slice.len;
                };
            } else unreachable,
        }
    }

    pub fn end(self: *Handler) ?Command {
        defer {
            self.state.deinit();
            self.state = .inactive;
        }

        return switch (self.state) {
            .inactive => unreachable,
            .ignore, .identify => null,
            .kitty => |*p| kitty: {
                if (comptime !build_options.kitty_graphics) unreachable;

                // Use the same allocator that was used to create the parser.
                const alloc = p.arena.child_allocator;
                const command = p.complete(alloc) catch |err| {
                    log.warn("kitty graphics protocol error: {}", .{err});
                    break :kitty null;
                };

                break :kitty .{ .kitty = command };
            },
        };
    }
};

pub const State = union(enum) {
    /// We're not in the middle of an APC command yet.
    inactive: void,

    /// We got an unrecognized APC sequence or the APC sequence we
    /// recognized became invalid. We're just dropping bytes.
    ignore: void,

    /// We're waiting to identify the APC sequence. This is done by
    /// inspecting the first byte of the sequence.
    identify: void,

    /// Kitty graphics protocol
    kitty: if (build_options.kitty_graphics)
        kitty_gfx.CommandParser
    else
        void,

    pub fn deinit(self: *State) void {
        switch (self.*) {
            .inactive, .ignore, .identify => {},
            .kitty => |*v| if (comptime build_options.kitty_graphics)
                v.deinit()
            else
                unreachable,
        }
    }
};

/// Possible APC command types.
pub const Protocol = enum {
    kitty,

    /// Returns the default maximum bytes for the given protocol.
    pub fn defaultMaxBytes(self: Protocol) usize {
        return switch (self) {
            // Kitty graphics payloads can be very large (e.g. full images
            // encoded as base64), so the default is set to 65 MiB.
            .kitty => 65 * 1024 * 1024,
        };
    }
};

/// Possible APC commands.
pub const Command = union(Protocol) {
    kitty: if (build_options.kitty_graphics)
        kitty_gfx.Command
    else
        void,

    pub fn deinit(self: *Command, alloc: Allocator) void {
        switch (self.*) {
            .kitty => |*v| if (comptime build_options.kitty_graphics)
                v.deinit(alloc)
            else
                unreachable,
        }
    }
};

test "unknown APC command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    h.start();
    for ("Xabcdef1234") |c| h.feed(alloc, c);
    try testing.expect(h.end() == null);
}

test "garbage Kitty command" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    h.start();
    for ("Gabcdef1234") |c| h.feed(alloc, c);
    try testing.expect(h.end() == null);
}

test "Kitty command with overflow u32" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    h.start();
    for ("Ga=p,i=10000000000") |c| h.feed(alloc, c);
    try testing.expect(h.end() == null);
}

test "Kitty command with overflow i32" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    h.start();
    for ("Ga=p,i=1,z=-9999999999") |c| h.feed(alloc, c);
    try testing.expect(h.end() == null);
}

test "kitty feed error deinits parser" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    // Feed a valid kitty command start to allocate parser state, then
    // trigger an error during feed via an integer overflow. The testing
    // allocator will detect leaks if deinit is not called.
    var h: Handler = .{};
    defer h.deinit();
    h.start();
    for ("Ga=p,i=10000000000;") |c| h.feed(alloc, c);
    try testing.expect(h.state == .ignore);
}

/// A test allocator that records the most bytes it ever had live, and
/// refuses to go past `ceiling` so a missing cap fails the test instead
/// of taking the machine's memory.
const HighWaterAllocator = struct {
    child: Allocator,
    ceiling: usize,
    live: usize = 0,
    peak: usize = 0,

    fn allocator(self: *HighWaterAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn grow(self: *HighWaterAllocator, old_len: usize, new_len: usize) bool {
        const live = self.live - old_len + new_len;
        if (live > self.ceiling) return false;
        self.live = live;
        self.peak = @max(self.peak, live);
        return true;
    }

    fn alloc(ctx: *anyopaque, len: usize, a: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *HighWaterAllocator = @ptrCast(@alignCast(ctx));
        if (!self.grow(0, len)) return null;
        return self.child.rawAlloc(len, a, ra) orelse {
            self.live -= len;
            return null;
        };
    }

    fn resize(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *HighWaterAllocator = @ptrCast(@alignCast(ctx));
        const live = self.live;
        if (!self.grow(mem.len, new_len)) return false;
        if (self.child.rawResize(mem, a, new_len, ra)) return true;
        self.live = live;
        return false;
    }

    fn remap(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *HighWaterAllocator = @ptrCast(@alignCast(ctx));
        const live = self.live;
        if (!self.grow(mem.len, new_len)) return null;
        return self.child.rawRemap(mem, a, new_len, ra) orelse {
            self.live = live;
            return null;
        };
    }

    fn free(ctx: *anyopaque, mem: []u8, a: std.mem.Alignment, ra: usize) void {
        const self: *HighWaterAllocator = @ptrCast(@alignCast(ctx));
        self.child.rawFree(mem, a, ra);
        self.live -= mem.len;
    }
};

test "kitty max bytes exceeded" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{ .max_bytes = .init(.{ .kitty = 4 }) };
    defer h.deinit();
    h.start();
    // 'G' identifies kitty, 'a=t;' moves to data state, then feed exceeds max_bytes.
    for ("Ga=t;") |c| h.feed(alloc, c);
    try testing.expect(h.state != .ignore);
    for ("abcd") |c| h.feed(alloc, c);
    try testing.expect(h.state != .ignore);
    // The 5th data byte exceeds the 4-byte limit.
    h.feed(alloc, 'e');
    try testing.expect(h.state == .ignore);
}

test "kitty unterminated 512 MiB payload stays under the cap" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    const testing = std.testing;
    const mib = 1024 * 1024;

    // The cap a terminal gets by default.
    try testing.expectEqual(@as(?usize, 65 * mib), (Handler{}).max_bytes.get(.kitty));

    // A smaller cap keeps the test light; the input is what a hostile
    // remote would send, 512 MiB with no terminator.
    const cap = mib;
    var hw: HighWaterAllocator = .{
        .child = std.heap.page_allocator,
        .ceiling = 256 * mib,
    };
    const alloc = hw.allocator();

    var h: Handler = .{ .max_bytes = .init(.{ .kitty = cap }) };
    defer h.deinit();
    h.start();
    for ("Ga=t;") |c| h.feed(alloc, c);
    for (0..cap) |_| h.feed(alloc, 'A');
    try testing.expect(h.state != .ignore);

    // One byte past the cap drops the command and frees its buffer.
    h.feed(alloc, 'A');
    try testing.expect(h.state == .ignore);
    try testing.expectEqual(@as(usize, 0), hw.live);

    // The rest of the sequence costs nothing.
    for (cap + 1..512 * mib) |_| h.feed(alloc, 'A');
    try testing.expectEqual(@as(usize, 0), hw.live);
    try testing.expect(h.end() == null);

    // The payload list grows by half again, and the old buffer is still
    // live while it is copied, so the peak stays under 2.5 times the cap.
    try testing.expect(hw.peak <= cap * 5 / 2);
}

test "valid Kitty command" {
    if (comptime !build_options.kitty_graphics) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    h.start();
    const input = "Gf=24,s=10,v=20,hello=world";
    for (input) |c| h.feed(alloc, c);

    var cmd = h.end().?;
    defer cmd.deinit(alloc);
    try testing.expect(cmd == .kitty);
}
