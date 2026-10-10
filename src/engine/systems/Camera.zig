const std = @import("std");
const core = @import("../../root.zig");
const log = std.log.scoped(.Camera);
const vk = core.clibs.vk;
const imgui = core.clibs.imgui;
const Vec3 = core.lib.math.Vec3;
const Vec4 = core.lib.math.Vec4;
const Mat4 = core.lib.math.Mat4;

screen_extent: vk.Extent2D,

main_camera_entity: ?u32 = null,
gpu_camera: ?GPUData = null,

pub const GPUData = struct {
    view: Mat4,
    proj: Mat4,
};

pub const CAMERA_SET_NAME = "camera_set";
pub const CAMERA_RESOURCE_NAME = "camera";

pub fn init(
    a: std.mem.Allocator,
    resources: *core.resources.Manager,
    swapchain_extent: vk.Extent2D,
) std.mem.Allocator.Error!@This() {
    try resources.mapped_buffers.creates.put(
        a,
        CAMERA_RESOURCE_NAME,
        .{
            .alloc_size = @sizeOf(GPUData),
            .buffer_usage = vk.BUFFER_USAGE_UNIFORM_BUFFER_BIT,
            .mem_usage = core.clibs.vma.MEMORY_USAGE_CPU_TO_GPU,
            .flags = 0,
        },
    );

    return .{
        .screen_extent = swapchain_extent,
    };
}

pub fn initEntities(
    self: *@This(),
    world: *core.engine.world.GameWorld,
    _: *const core.resources.Manager,
) std.mem.Allocator.Error!void {
    const camera = Controller{
        .screen_extent = self.screen_extent,
    };
    const start_pos =
        core.lib.math.Vec3.ONE.mul(4.0);

    const transform = core.engine.world.WorldTransform{
        .position = start_pos,
        .rotation = .lookAt(start_pos, .ZERO),
    };

    var ent = try world.entities.register("main_camera");
    ent.addComponent(.camera, camera);
    ent.addComponent(.world_transform, transform);

    self.main_camera_entity = ent.identifier.*;
    self.gpu_camera = camera.gpuData(&transform);
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
    const aligned: *GPUData = @ptrCast(
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
    var cam: *Controller = (camera_ent.accessComponentPtr(.camera) catch @panic("No camera component?")).camera;
    const trans: *core.engine.world.WorldTransform = (camera_ent.accessComponentPtr(.world_transform) catch @panic("No transform component?")).world_transform;

    cam.control(&self.gpu_camera.?, trans, dt, input);
}

pub fn drawImgui(self: *@This(), ctx: core.engine.systems.manager.DrawImguiContext) void {
    var open = true;
    const shown = imgui.Begin("Camera System", &open, core.clibs.imgui.WINDOW_ALWAYS_AUTO_RESIZE);
    defer imgui.End();

    if (!shown) return;

    var camera_ent = ctx.world.entityHandle(self.main_camera_entity.?) catch @panic("No entity??");
    var cam: *Controller =
        (camera_ent.accessComponentPtr(.camera) catch @panic("No camera component?")).camera;
    const trans: *core.engine.world.WorldTransform =
        (camera_ent.accessComponentPtr(.world_transform) catch @panic("No transform component?")).world_transform;

    _ = imgui.DragFloat("FOV", &cam.fov);
    _ = imgui.DragFloat("Near", &cam.near_plane);
    _ = imgui.DragFloat("Far", &cam.far_plane);

    _ = imgui.DragFloat("Move speed", &cam.movement_speed);
    _ = imgui.DragFloat("Mouse sensitivity", &cam.mouse_sensitivity);
    _ = imgui.Checkbox("Constrain pitch", &cam.constrain_pitch);

    const pos = trans.position;
    imgui.Text("Camera Pos: (%.2f, %.2f, %.2f)", pos.x, pos.y, pos.z);

    var angles = Controller.Angles.fromRotation(&trans.rotation);
    _ = imgui.DragFloat("Yaw", &angles.yaw);
    _ = imgui.DragFloat("Pitch", &angles.pitch);

    const fwd = trans.rotation.forwardVec3();
    imgui.Text("Camera fwd: (%.2f, %.2f, %.2f)", fwd.x, fwd.y, fwd.z);
    const target = fwd.add(pos);
    imgui.Text("Camera target: (%.2f, %.2f, %.2f)", target.x, target.y, target.z);
}

pub const Controller = struct {
    /// for aspect ratio
    screen_extent: vk.Extent2D,

    fov: f32 = 45.0,
    near_plane: f32 = 0.1,
    far_plane: f32 = 100.0,

    movement_speed: f32 = 5.0,
    mouse_sensitivity: f32 = 0.002,
    min_fov: f32 = 1.0,
    max_fov: f32 = 45.0,
    constrain_pitch: bool = true,

    pub const Angles = struct {
        yaw: f32,
        pitch: f32,

        pub fn fromRotation(rot: *const Vec4) Angles {
            const f = rot.forwardVec3();
            return .{
                .yaw = std.math.atan2(f.x, f.y),
                .pitch = std.math.asin(std.math.clamp(f.z, -1.0, 1.0)),
            };
        }

        fn toRotation(a: Angles) Vec4 {
            const sy = @sin(a.yaw * 0.5);
            const cy = @cos(a.yaw * 0.5);
            const sp = @sin(a.pitch * 0.5);
            const cp = @cos(a.pitch * 0.5);
            return Vec4.make(
                cy * sp,
                -sy * sp,
                -sy * cp,
                cy * cp,
            );
        }
    };
    pub const Basis = struct {
        front: Vec3,
        right: Vec3,
        up: Vec3,

        pub fn fromTransformRotation(rot: *const Vec4) Basis {
            const a = Angles.fromRotation(rot);
            const sy = @sin(a.yaw);
            const cy = @cos(a.yaw);
            const sp = @sin(a.pitch);
            const cp = @cos(a.pitch);
            return .{
                .front = Vec3.make(cp * sy, cp * cy, sp),
                .right = Vec3.make(cy, -sy, 0.0),
                .up = Vec3.make(-sp * sy, -sp * cy, cp),
            };
        }
    };

    pub const Movement = enum {
        forward,
        backward,
        left,
        right,
        up,
        down,
    };

    pub fn processKeyboard(
        self: Controller,
        transform: *core.engine.world.WorldTransform,
        direction: Movement,
        dt: f32,
    ) void {
        const b = Basis.fromTransformRotation(&transform.rotation);
        const v = self.movement_speed * dt;
        transform.position = switch (direction) {
            .forward => transform.position.add(b.front.mul(v)),
            .backward => transform.position.sub(b.front.mul(v)),
            .right => transform.position.add(b.right.mul(v)),
            .left => transform.position.sub(b.right.mul(v)),
            .up => transform.position.add(b.up.mul(v)),
            .down => transform.position.sub(b.up.mul(v)),
        };
    }

    pub fn processMouseMovement(
        self: *Controller,
        rot: *Vec4,
        x_offset: f32,
        y_offset: f32,
    ) void {
        if (x_offset == 0 and y_offset == 0) return; // don't touch the transform when idle

        var a = Angles.fromRotation(rot);
        a.yaw += x_offset * self.mouse_sensitivity;
        a.pitch -= y_offset * self.mouse_sensitivity;
        if (self.constrain_pitch) {
            const limit = std.math.pi / 2.0 - 0.01;
            a.pitch = std.math.clamp(a.pitch, -limit, limit);
        }

        rot.* = a.toRotation();
    }

    pub fn processMouseScroll(self: *Controller, y_offset: f32) void {
        self.fov = std.math.clamp(self.fov - y_offset, self.min_fov, self.max_fov);
    }

    pub fn control(
        self: *@This(),
        gpu_data: *GPUData,
        transform: *core.engine.world.WorldTransform,
        dt: f32,
        input: core.engine.Input,
    ) void {
        if (input.isDown(.W)) self.processKeyboard(transform, .forward, dt);
        if (input.isDown(.S)) self.processKeyboard(transform, .backward, dt);
        if (input.isDown(.A)) self.processKeyboard(transform, .left, dt);
        if (input.isDown(.D)) self.processKeyboard(transform, .right, dt);
        self.processMouseMovement(&transform.rotation, input.mouse_delta.x, input.mouse_delta.y);
        self.processMouseScroll(input.scroll);
        gpu_data.* = self.gpuData(transform);
    }

    pub fn projectionMatrix(self: Controller) Mat4 {
        const aspect =
            @as(f32, @floatFromInt(self.screen_extent.width)) /
            @as(f32, @floatFromInt(self.screen_extent.height));
        var proj = Mat4.perspective(self.fov, aspect, self.near_plane, self.far_plane);
        proj.j.y *= -1;
        return proj;
    }

    pub fn viewMatrix(transform: *const core.engine.world.WorldTransform) Mat4 {
        const fwd = transform.rotation.forwardVec3();
        const target = Vec3{
            .x = transform.position.x + fwd.x,
            .y = transform.position.y + fwd.y,
            .z = transform.position.z + fwd.z,
        };

        return Mat4.lookAt(transform.position, target);
    }

    pub fn gpuData(self: Controller, transform: *const core.engine.world.WorldTransform) GPUData {
        return .{
            .view = viewMatrix(transform),
            .proj = self.projectionMatrix(),
        };
    }
};
