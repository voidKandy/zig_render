const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.PipelineManager);
const c = @import("clibs.zig");
const PipelineBuilder = @import("PipelineBuilder.zig");
const vki = @import("vulkan_init.zig");
const vk = c.vk;
const vma = c.vma;

/// anything engine can pass to the draw function
/// I expect this type to grow
/// should include READ ONLY data
pub const DrawData = struct {
    swapchain: vki.Swapchain,
    image_index: usize,
};
pub const InitData = struct {
    swapchain_extent: vk.Extent2D,
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

pub fn deinit(
    self: *@This(),
    vma_a: vma.Allocator,
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

pub fn drawByKey(self: *@This(), key: []const u8, draw_data: DrawData, cmd: vk.CommandBuffer) void {
    const idx = self.idx_map.get(key) orelse return;
    const entry = self.entries.items[idx];
    entry.draw(draw_data, cmd);
}

pub const Entry = struct {
    const DrawImguiFunc = fn (*anyopaque) void;
    const DrawFunc = fn (*anyopaque, DrawData, vk.CommandBuffer) void;
    const CleanupFunc = fn (*anyopaque, Allocator, vma.Allocator, vk.Device, ?*vk.AllocationCallbacks) void;
    const InitializeFunc = fn (
        *anyopaque,
        Allocator,
        vma.Allocator,
        InitData,
        *vki.UploadContext,
        vki.LogicalDevice,
        vk.RenderPass,
        ?*vk.AllocationCallbacks,
    ) anyerror!void;

    drawFunc: *const DrawFunc,
    drawImguiFunc: ?*const DrawImguiFunc,
    initializeFunc: *const InitializeFunc,
    cleanupFunc: *const CleanupFunc,
    data_ptr: *anyopaque,

    /// Describes the interface of a PipelineManager.Entry
    /// Each of these variants denotes the expected function type for the entry.
    const ExpectedFunctions = enum {
        draw,
        drawImgui,
        initialize,
        deinit,

        inline fn initAll() [std.meta.fields(@This()).len]@This() {
            comptime {
                var all: [std.meta.fields(@This()).len]@This() = undefined;
                for (0..std.meta.fields(@This()).len) |i| {
                    all[i] = @enumFromInt(i);
                }
                return all;
            }
        }

        inline fn funcType(self: @This()) type {
            comptime return switch (self) {
                .draw => DrawFunc,
                .drawImgui => DrawImguiFunc,
                .initialize => InitializeFunc,
                .deinit => CleanupFunc,
            };
        }

        fn TypeOfFunctionOnType(self: @This(), comptime T: type) ?type {
            return switch (self) {
                .draw => @TypeOf(T.draw),
                .drawImgui => if (@hasDecl(T, @tagName(self))) @TypeOf(T.drawImgui) else null,
                .initialize => @TypeOf(T.initialize),
                .deinit => @TypeOf(T.deinit),
            };
        }
    };

    inline fn validateT(comptime T: type) void {
        comptime {
            for (ExpectedFunctions.initAll()) |e| {
                if (!@hasDecl(T, @tagName(e))) {
                    // .drawImgui function is optional
                    if (e == .drawImgui) continue;
                    @compileError("type '" ++ @typeName(T) ++ "' must have a public: '" ++ @tagName(e) ++ "' declaration");
                }

                const info = @typeInfo(ExpectedFunctions.TypeOfFunctionOnType(e, T).?);
                functionsArgumentsMatch(
                    @tagName(e),
                    info.@"fn",
                    @typeInfo(ExpectedFunctions.funcType(e)).@"fn",
                );
            }
            for (@typeInfo(T).@"struct".fields) |field|
                if (field.default_value_ptr == null) @compileError("field '" ++ field.name ++ "' must have a default value");
        }
    }

    inline fn functionsArgumentsMatch(comptime name: []const u8, comptime func: std.builtin.Type.Fn, comptime other: std.builtin.Type.Fn) void {
        const expected_params = other.params;
        const params = func.params;
        std.debug.assert(params.len == expected_params.len);
        inline for (0..params.len) |i| {
            if (expected_params[i].type.? == *anyopaque and i == 0) continue;
            if (params[i].type.? != expected_params[i].type.?) @compileError("function '" ++ name ++ "' has invalid parameter type: " ++ @typeName(params[i].type.?) ++ " expected: " ++ @typeName(expected_params[i].type.?));
        }
    }

    /// Creates a new instance of the given type with default values.
    pub fn create(
        comptime T: type,
        allocator: Allocator,
    ) Allocator.Error!Entry {
        const ptr = try allocator.create(T);
        ptr.* = T{};

        validateT(T);
        return .{
            .data_ptr = @ptrCast(ptr),
            .drawFunc = &struct {
                fn d(p: *anyopaque, dat: DrawData, cmd: vk.CommandBuffer) void {
                    @as(*T, @ptrCast(@alignCast(p))).draw(dat, cmd);
                }
            }.d,
            .drawImguiFunc = if (@hasDecl(T, @tagName(.drawImgui))) &struct {
                fn d(p: *anyopaque) void {
                    @as(*T, @ptrCast(@alignCast(p))).drawImgui();
                }
            }.d else null,
            .initializeFunc = &struct {
                fn i(p: *anyopaque, a: Allocator, vma_a: vma.Allocator, idat: InitData, ctx: *vki.UploadContext, logi: vki.LogicalDevice, rp: vk.RenderPass, cbs: ?*vk.AllocationCallbacks) anyerror!void {
                    try @as(*T, @ptrCast(@alignCast(p))).initialize(a, vma_a, idat, ctx, logi, rp, cbs);
                }
            }.i,
            .cleanupFunc = &struct {
                fn c(p: *anyopaque, a: Allocator, vma_a: vma.Allocator, d: vk.Device, cbs: ?*vk.AllocationCallbacks) void {
                    const pt: *T = @ptrCast(@alignCast(p));
                    defer a.destroy(pt);
                    pt.deinit(a, vma_a, d, cbs);
                }
            }.c,
        };
    }

    pub fn init(
        self: *@This(),
        a: Allocator,
        vma_a: vma.Allocator,
        init_data: InitData,
        upload_ctx: *vki.UploadContext,
        device: vki.LogicalDevice,
        render_pass: vk.RenderPass,
        alloc_cbs: ?*vk.AllocationCallbacks,
    ) void {
        self.initializeFunc(
            self.data_ptr,
            a,
            vma_a,
            init_data,
            upload_ctx,
            device,
            render_pass,
            alloc_cbs,
        ) catch |err| {
            log.err("Failed to initialize pipeline manager: {}", .{err});
            @panic("Failed initialization");
        };
    }

    pub fn deinit(self: @This(), allocator: Allocator, vma_a: vma.Allocator, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
        self.cleanupFunc(self.data_ptr, allocator, vma_a, device, alloc_cbs);
    }

    /// should return a result?
    pub fn draw(self: @This(), draw_data: DrawData, command_buffer: vk.CommandBuffer) void {
        self.drawFunc(self.data_ptr, draw_data, command_buffer);
    }

    pub fn drawImgui(self: @This()) void {
        const func = self.drawImguiFunc orelse @panic("tried to drawImgui on an Entry without a drawImguiFunc");
        func(self.data_ptr);
    }
};
