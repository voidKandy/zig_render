const std = @import("std");
const core = @import("../../root.zig");
const log = std.log.scoped(.Camera);
const vk = core.clibs.vk;
const imgui = core.clibs.imgui;
const Camera = core.engine.Camera;

camera: Camera,
gpu_camera: Camera.GPUData,

pub const CAMERA_SET_NAME = "camera_set";
pub const CAMERA_RESOURCE_NAME = "camera";

pub fn init(camera: Camera, swapchain_extent: vk.Extent2D) std.mem.Allocator.Error!@This() {
    const gpu = Camera.GPUData.fromCamera(camera, swapchain_extent);
    return .{
        .camera = camera,
        .gpu_camera = gpu,
    };
}

pub fn registerSets(a: std.mem.Allocator, device: vk.Device, resources: *core.resources.Manager, alloc_cbs: ?*vk.AllocationCallbacks) std.mem.Allocator.Error!void {
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
pub fn trySyncResources(self: *@This(), alloc_resources: core.resources.Manager.AllocatedData) void {
    const aligned: *Camera.GPUData = @ptrCast(
        @alignCast(alloc_resources.mapped_buffers.buffers.get(CAMERA_RESOURCE_NAME).?.mapped),
    );
    aligned.* = self.gpu_camera;
}

pub fn update(
    self: *@This(),
    engine: core.engine.Engine,
) void {
    self.camera.control(engine.io, &self.gpu_camera, engine.input, engine.swapchain.extent);
}

pub fn drawImgui(self: *@This()) void {
    var open = true;
    const shown = imgui.Begin("Camera System", &open, core.clibs.imgui.WINDOW_ALWAYS_AUTO_RESIZE);
    defer imgui.End();

    if (!shown) return;

    const current_mode_name = @tagName(self.camera.mode);
    if (imgui.BeginCombo("Modes", current_mode_name.ptr, 0)) {
        defer imgui.EndCombo();

        for (std.meta.tags(Camera.Mode)) |tag| {
            const name = @tagName(tag);
            if (imgui.Selectable(name))
                self.camera.mode = tag;
        }
    }

    const pos = self.camera.eye; // adjust field name to whatever your Camera struct calls it
    imgui.Text("Camera Pos: (%.2f, %.2f, %.2f)", pos.x, pos.y, pos.z);
}
