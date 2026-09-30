const std = @import("std");
const core = @import("../../root.zig");
const log = std.log.scoped(.Camera);
const vk = core.clibs.vk;
const imgui = core.clibs.imgui;
const Camera = core.engine.Camera;

screen_extent: vk.Extent2D,

main_camera_entity: ?u32 = null,
gpu_camera: ?Camera.GPUData = null,

pub const CAMERA_SET_NAME = "camera_set";
pub const CAMERA_RESOURCE_NAME = "camera";

pub fn init(
    a: std.mem.Allocator,
    resources: *core.resources.Manager,
    // world: *core.engine.world.GameWorld,
    swapchain_extent: vk.Extent2D,
) std.mem.Allocator.Error!@This() {
    // const camera = Camera{
    // .screen_extent = swapchain_extent,
    // };
    // const gpu = Camera.GPUData.fromCamera(camera, swapchain_extent);

    try resources.mapped_buffers.creates.put(
        a,
        CAMERA_RESOURCE_NAME,
        .{
            .alloc_size = @sizeOf(Camera.GPUData),
            .buffer_usage = vk.BUFFER_USAGE_UNIFORM_BUFFER_BIT,
            .mem_usage = core.clibs.vma.MEMORY_USAGE_CPU_TO_GPU,
            .flags = 0,
        },
    );

    // var ent = try world.entities.register("main_camera");
    // ent.addComponent(.camera, camera);
    return .{
        .screen_extent = swapchain_extent,
        // .main_camera_entity = ent.identifier.*,
        // .gpu_camera = gpu,
    };
}

pub fn initEntities(
    self: *@This(),
    world: *core.engine.world.GameWorld,
    _: *const core.resources.Manager,
) std.mem.Allocator.Error!void {
    const camera = Camera{
        .screen_extent = self.screen_extent,
    };
    var ent = try world.entities.register("main_camera");
    ent.addComponent(.camera, camera);

    self.main_camera_entity = ent.identifier.*;
    self.gpu_camera = Camera.GPUData.fromCamera(camera);
}

pub fn registerSets(
    a: std.mem.Allocator,
    device: vk.Device,
    resources: *core.resources.Manager,
    alloc_cbs: ?*vk.AllocationCallbacks,
) std.mem.Allocator.Error!void {
    try resources.mapped_buffers.createAndRegisterBufferSetLayout(
        a,
        CAMERA_SET_NAME,
        &[_]core.resources.MappedBuffers.CreateBufferInfo{
            .{
                .name = CAMERA_RESOURCE_NAME,
                .descriptor_type = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .binding = 0,
                .stage_flags = vk.SHADER_STAGE_VERTEX_BIT | vk.SHADER_STAGE_COMPUTE_BIT,
            },
        },
        device,
        alloc_cbs,
    );
}

pub fn updateSets(
    device: vk.Device,
    allocated_resources: *core.resources.Manager.AllocatedData,
) void {
    allocated_resources.mapped_buffers.updateBufferSet(
        device,
        CAMERA_SET_NAME,
    );
}

pub fn syncResources(self: *@This(), alloc_resources: core.resources.Manager.AllocatedData) void {
    const aligned: *Camera.GPUData = @ptrCast(
        @alignCast(alloc_resources.mapped_buffers.buffers.get(CAMERA_RESOURCE_NAME).?.mapped),
    );
    aligned.* = self.gpu_camera.?;
}

pub fn update(
    self: *@This(),
    dt: f32,
    input: core.engine.Input,
    world: *core.engine.world.GameWorld,
) void {
    var camera_ent = world.entityHandle(self.main_camera_entity.?) catch @panic("No entity??");
    var comp = camera_ent.accessComponentPtr(.camera) catch @panic("No camera component?");
    comp.camera.control(&self.gpu_camera.?, dt, input);
}

pub fn drawImgui(self: *@This(), ctx: core.engine.systems.manager.DrawImguiContext) void {
    var open = true;
    const shown = imgui.Begin("Camera System", &open, core.clibs.imgui.WINDOW_ALWAYS_AUTO_RESIZE);
    defer imgui.End();

    // var camera_ent = engine.world.entityHandle(self.main_camera_entity) catch @panic("No entity??");
    // var comp = camera_ent.accessComponent(.camera) catch @panic("No camera component?");
    // const camera = comp.camera;
    if (!shown) return;

    var camera_ent = ctx.world.entityHandle(self.main_camera_entity.?) catch @panic("No entity??");
    var comp = camera_ent.accessComponentPtr(.camera) catch @panic("No camera component?");

    const current_mode_name = @tagName(comp.camera.mode);
    if (imgui.BeginCombo("Modes", current_mode_name.ptr, 0)) {
        defer imgui.EndCombo();

        for (std.meta.tags(Camera.Mode)) |tag| {
            const name = @tagName(tag);
            if (imgui.Selectable(name))
                comp.camera.mode = tag;
        }
    }

    const pos = comp.camera.eye; // adjust field name to whatever your Camera struct calls it
    imgui.Text("Camera Pos: (%.2f, %.2f, %.2f)", pos.x, pos.y, pos.z);
}
