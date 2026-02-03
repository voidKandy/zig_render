const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.Pipelines);
const c = @import("clibs.zig");
const vk = c.vk;

/// anything engine can pass to the draw function
/// I expect this type to grow
/// should include READ ONLY data
pub const DrawData = struct {
    swapchain_extent: vk.Extent2D = .{},
};

const DrawFunc = fn (*anyopaque, DrawData, vk.CommandBuffer) void;

pub const Entry = struct {
    data_ptr: *anyopaque,
    func_ptr: *const anyopaque,
    cleanupFunc: *const fn (@This(), Allocator, c.vma.Allocator, vk.Device, ?*vk.AllocationCallbacks) void,
    pipeline: vk.Pipeline = undefined,
    layout: vk.PipelineLayout = undefined,

    pub fn init(
        comptime T: type,
        ptr: *T,
        func: *const fn (T, DrawData, vk.CommandBuffer) void,
    ) Entry {
        return Entry{
            .data_ptr = @ptrCast(ptr),
            .func_ptr = @ptrCast(func),
            .cleanupFunc = &struct {
                fn de(self: Entry, a: Allocator, vma_a: c.vma.Allocator, d: vk.Device, cbs: ?*vk.AllocationCallbacks) void {
                    const p: *T = @ptrCast(@alignCast(self.data_ptr));
                    defer a.destroy(p);
                    if (@hasDecl(T, "deinit")) {
                        validateEntryDeinitFunction(@typeInfo(@TypeOf(T.deinit)));
                        T.deinit(p, a, vma_a, d, cbs);
                    }
                }
            }.de,
        };
    }

    pub fn deinit(self: @This(), allocator: Allocator, vma_a: c.vma.Allocator, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
        self.cleanupFunc(self, allocator, vma_a, device, alloc_cbs);
        vk.DestroyPipeline(device, self.pipeline, alloc_cbs);
        vk.DestroyPipelineLayout(device, self.layout, alloc_cbs);
    }

    /// should return a result
    pub fn callDraw(self: @This(), draw_data: DrawData, command_buffer: vk.CommandBuffer) void {
        @call(.auto, @as(
            *const DrawFunc,
            @ptrCast(@alignCast(self.func_ptr)),
        ), .{
            self.data_ptr, draw_data, command_buffer,
        });
    }
};

idx_map: std.StringHashMap(usize),
entries: std.ArrayList(Entry),
allocator: Allocator,

const Pipelines = @This();

pub fn init(a: Allocator) @This() {
    return .{
        .idx_map = .init(a),
        .allocator = a,
        .entries = std.ArrayList(Entry).initCapacity(a, 16) catch @panic("OOM"),
    };
}

inline fn validateEntryDeinitFunction(comptime info: std.builtin.Type) void {
    if (info != .@"fn") @compileError("validator was not passed a function");
    const expected_args_types = [_]?type{ null, Allocator, c.vma.Allocator, vk.Device, ?*vk.AllocationCallbacks };
    const params = info.@"fn".params;
    std.debug.assert(params.len == expected_args_types.len);
    inline for (0..params.len) |i|
        if (expected_args_types[i] != null and params[i].type.? != expected_args_types[i].?) @compileError("invalid parameter type");
}

pub fn deinit(
    self: *@This(),
    vma_a: c.vma.Allocator,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    defer self.entries.deinit(self.allocator);
    for (self.entries.items) |entry| {
        entry.deinit(self.allocator, vma_a, device, alloc_cbs);
    }
    self.idx_map.deinit();
}

pub fn insert(self: *@This(), key: []const u8, entry: Entry) Allocator.Error!void {
    const idx = self.entries.items.len;
    try self.idx_map.put(key, idx);
    self.entries.appendAssumeCapacity(entry);
}

pub fn runByKey(self: *@This(), key: []const u8, draw_data: DrawData, cmd: vk.CommandBuffer) void {
    const idx = self.idx_map.get(key) orelse return;
    const entry = self.entries.items[idx];
    entry.callDraw(draw_data, cmd);
}

test "Pipelines" {
    const pipelines = Pipelines.init(std.testing.allocator);
    defer pipelines.deinit();

    const MyData = struct {
        data: []const u8,
    };

    const drawFn =
        &struct {
            fn draw(dat: DrawData, d: MyData, cmd: vk.CommandBuffer) void {
                std.debug.panic(
                    \\ DATA: {s}
                , .{d.data});
                _ = cmd;
                _ = dat;
            }
        }.draw;

    const entry = Pipelines.Entry.init(MyData, .{ .data = "hello" }, drawFn);

    try pipelines.insert("test", entry);

    pipelines.runByKey("test", .{}, std.mem.zeroInit(vk.CommandBuffer, .{}));
}
