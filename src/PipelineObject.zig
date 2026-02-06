const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.PipelineObject);
const c = @import("clibs.zig");
const PipelineBuilder = @import("PipelineBuilder.zig");
const ResourceManager = @import("ResourceManager.zig");
const descriptor = @import("descriptor.zig");
const vki = @import("vulkan_init.zig");
const vk = c.vk;
const vma = c.vma;

/// The `PipelineObject` struct represents some render pipeline and all objects associated with it.
/// It contains a draw function, an optional drawImgui function, an initialize function, a cleanup function, and a pointer to user data.
/// The `create` function initializes an instance of `T` and returns a `PipelineNode` with the appropriate function pointers and data pointer.
/// The `draw` function calls the draw function of the `PipelineNode` instance.
/// The `drawImgui` function calls the drawImgui function of the `PipelineNode` instance if it exists.
/// The `init` function calls the initialize function of the `PipelineNode` instance.
/// The `deinit` function calls the cleanup function of the `PipelineNode` instance.
///
/// This makes it very easy to create and manage render pipelines as well as their data.
///
/// I forsee that at some point, this should be refactored to use some querying mechanism against some global data instead of managing its
/// own data.
/// This way, pipelines could share data and resources could be managed more efficiently.
pub const DrawData = struct {
    resources: ResourceManager,
    swapchain: vki.Swapchain,
    image_index: usize,
};
pub const InitData = struct {
    swapchain_extent: vk.Extent2D,
    resources: ResourceManager,
};

pub const Allocators = struct {
    std: Allocator,
    vma: vma.Allocator,
    descriptor: *descriptor.Allocator,
};

const DrawImguiFunc = fn (*anyopaque) void;
const DrawFunc = fn (*anyopaque, DrawData, vk.CommandBuffer) void;
const DeinitFunc = fn (*anyopaque, Allocators, vk.Device, ?*vk.AllocationCallbacks) void;
const InitFunc = fn (
    *anyopaque,
    Allocators,
    InitData,
    []const ResourceManager.ResourceID,
    // *vki.UploadContext,
    vki.LogicalDevice,
    vk.RenderPass,
    ?*vk.AllocationCallbacks,
) anyerror!void;

drawFunc: *const DrawFunc,
drawImguiFunc: ?*const DrawImguiFunc,
initializeFunc: *const InitFunc,
cleanupFunc: *const DeinitFunc,
data_ptr: *anyopaque,

/// Implicitly zero-initializes instance of `T`
pub fn create(
    comptime T: type,
    allocator: Allocator,
) Allocator.Error!@This() {
    comptime validateT(T);
    const ptr = try allocator.create(T);
    ptr.* = T{};

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
            fn i(p: *anyopaque, allocs: Allocators, idat: InitData, r: []const ResourceManager.ResourceID, logi: vki.LogicalDevice, rp: vk.RenderPass, cbs: ?*vk.AllocationCallbacks) anyerror!void {
                try @as(*T, @ptrCast(@alignCast(p))).init(allocs, idat, r, logi, rp, cbs);
            }
        }.i,
        .cleanupFunc = &struct {
            fn c(p: *anyopaque, allocs: Allocators, d: vk.Device, cbs: ?*vk.AllocationCallbacks) void {
                const pt: *T = @ptrCast(@alignCast(p));
                defer allocs.std.destroy(pt);
                pt.deinit(allocs, d, cbs);
            }
        }.c,
    };
}

pub fn init(
    self: *@This(),
    allocs: Allocators,
    init_data: InitData,
    resources: []const ResourceManager.ResourceID,
    device: vki.LogicalDevice,
    render_pass: vk.RenderPass,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    self.initializeFunc(
        self.data_ptr,
        allocs,
        init_data,
        resources,
        device,
        render_pass,
        alloc_cbs,
    ) catch |err| {
        log.err("Failed to initialize pipeline manager: {}", .{err});
        @panic("Failed initialization");
    };
}

pub fn deinit(self: @This(), allocs: Allocators, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
    self.cleanupFunc(self.data_ptr, allocs, device, alloc_cbs);
}

/// should return a result?
pub fn draw(self: @This(), draw_data: DrawData, command_buffer: vk.CommandBuffer) void {
    self.drawFunc(self.data_ptr, draw_data, command_buffer);
}

pub fn drawImgui(self: @This()) void {
    const func = self.drawImguiFunc orelse @panic("tried to drawImgui on a PipelineNode without a drawImguiFunc");
    func(self.data_ptr);
}

/// Describes the interface of a `PipelineNode`
/// Used to validate `T` passed to `PipelineNode.init`
const ExpectedFunctions = enum {
    draw,
    drawImgui,
    init,
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
            .init => InitFunc,
            .deinit => DeinitFunc,
        };
    }

    fn TypeOfFunctionOnType(self: @This(), comptime T: type) ?type {
        return switch (self) {
            .draw => @TypeOf(T.draw),
            .drawImgui => if (@hasDecl(T, @tagName(self))) @TypeOf(T.drawImgui) else null,
            .init => @TypeOf(T.init),
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
