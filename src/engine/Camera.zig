const std = @import("std");
const core = @import("../root.zig");
const c = core.clibs;
const vk = c.vk;
const vki = core.bindings.vulkan_init;
const vma_usage = core.bindings.vma_usage;
const checkVk = vki.checkVk;
const math_mod = core.lib.math;
const Vec3 = math_mod.Vec3;
const Mat4 = math_mod.Mat4;

pub const AllocatedData = struct {
    uniform: vma_usage.MappedBuffer,

    pub fn deinit(self: *@This(), vma_a: c.vma.Allocator) void {
        self.uniform.deinit(vma_a);
    }

    pub const GPUData = struct {
        view: Mat4,
        proj: Mat4,

        fn fromCamera(camera: Camera, extent: vk.Extent2D) @This() {
            const aspect =
                @as(f32, @floatFromInt(extent.width)) /
                @as(f32, @floatFromInt(extent.height));
            var proj = Mat4.perspective(
                camera.fov,
                aspect,
                camera.near_plane,
                camera.far_plane,
            );
            proj.j.y *= -1;

            return .{
                .view = Mat4.lookAt(
                    camera.eye,
                    camera.target,
                    Vec3.UP,
                ),
                .proj = proj,
            };
        }
    };

    pub fn createFromCamera(vma_a: c.vma.Allocator, camera: Camera, camera_extent: vk.Extent2D) @This() {
        const camera_alloc = vma_usage.AllocatedBuffer.create(
            vma_a,
            @sizeOf(@This()),
            vk.BUFFER_USAGE_UNIFORM_BUFFER_BIT,
            c.vma.MEMORY_USAGE_CPU_TO_GPU,
            0,
        );
        var mapped_camera: vma_usage.MappedBuffer = .{ .allocation = camera_alloc };
        checkVk(core.clibs.vma.MapMemory(vma_a, camera_alloc.allocation, &mapped_camera.mapped)) catch @panic("Failed to map camera");

        const camera_gpu_data = GPUData.fromCamera(camera, camera_extent);
        const aligned_camera: *AllocatedData.GPUData = @ptrCast(@alignCast(mapped_camera.mapped));
        aligned_camera.* = camera_gpu_data;

        return .{
            .uniform = mapped_camera,
        };
    }

    pub fn descriptorSetLayoutBinding(
        binding: u32,
    ) vk.DescriptorSetLayoutBinding {
        return vk.DescriptorSetLayoutBinding{
            .binding = binding,
            .descriptorType = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .stageFlags = vk.SHADER_STAGE_VERTEX_BIT,
        };
    }

    pub fn allocateDescriptorSet(
        set: *vk.DescriptorSet,
        set_layout: vk.DescriptorSetLayout,
        pool: vk.DescriptorPool,
        device: vk.Device,
    ) void {
        const ai = vk.DescriptorSetAllocateInfo{
            .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &set_layout,
        };

        checkVk(vk.AllocateDescriptorSets(device, &ai, set)) catch
            @panic("failed to allocate descriptor sets");
    }
};

near_plane: f32 = 0.1,
far_plane: f32 = 100.0,
fov: f32 = 45.0,

eye: Vec3 = DEFAULT_EYE,
target: Vec3 = DEFAULT_TARGET,
distance: f32 = DEFAULT_EYE.eucDist(DEFAULT_TARGET),

mode: Mode = .user_input,
player_controller: PlayerController = .{},

const DEFAULT_EYE: Vec3 = Vec3.make(4.0, 4.0, 4.0);
const DEFAULT_TARGET: Vec3 = Vec3.make(0.0, 0.0, 1.0);

const Camera = @This();

pub const PlayerController = struct {
    yaw: f32 = 0.0,
    pitch: f32 = 0.0,
    speed: f32 = 50.0,
    sensitivity: f32 = 0.002,

    pub fn forward(self: PlayerController) Vec3 {
        return Vec3.make(
            @cos(self.pitch) * @sin(self.yaw),
            @cos(self.pitch) * @cos(self.yaw),
            @sin(self.pitch),
        );
    }

    pub fn right(self: PlayerController) Vec3 {
        return Vec3.make(
            @cos(self.yaw),
            -@sin(self.yaw),
            0,
        );
    }
};

pub const Mode = enum {
    rotate_around,
    user_input,
    player,
};

pub fn control(
    self: *@This(),
    io: std.Io,
    camera_uniform: core.bindings.vma_usage.MappedBuffer,
    input: core.engine.Input,
    screen_extent: vk.Extent2D,
) void {
    const State = struct {
        var start: i128 = 0;
        var yaw: f32 = 0.0;
        var last_time: i128 = 0;
    };
    if (State.start == 0) {
        State.start = std.Io.Timestamp.now(io, .real).toNanoseconds();
        State.last_time = State.start;
    }

    const zoom_speed = 0.1;
    const min_distance = 0.2;
    const max_distance = 10.0;

    if (self.mode != .player) {
        self.distance = std.math.clamp(self.distance - input.scroll * zoom_speed, min_distance, max_distance);
        const dir = self.target.sub(self.eye).normalized();
        self.eye = self.target.sub(dir.mul(self.distance));
    }

    const now = std.Io.Timestamp.now(io, .real).toNanoseconds();
    const dt: f32 = @as(f32, @floatFromInt(now - State.last_time)) / @as(f32, @floatFromInt(std.time.ns_per_s));
    State.last_time = now;

    const delta_ns = now - State.start;
    const time: f32 = @as(f32, (@floatFromInt(delta_ns))) / @as(f32, (@floatFromInt(std.time.ns_per_s)));
    State.yaw = time * 1.0;

    const aspect =
        @as(f32, @floatFromInt(screen_extent.width)) /
        @as(f32, @floatFromInt(screen_extent.height));

    const eye = Vec3.make(
        self.target.x + self.distance * @sin(State.yaw),
        self.target.y + self.distance * @cos(State.yaw),
        self.target.z,
    );
    // player mode update
    if (self.mode == .player) {

        // mouse look
        self.player_controller.yaw += input.mouse_delta.x * self.player_controller.sensitivity;
        self.player_controller.pitch -= input.mouse_delta.y * self.player_controller.sensitivity;
        self.player_controller.pitch = std.math.clamp(
            self.player_controller.pitch,
            -std.math.pi / 2.0 + 0.01,
            std.math.pi / 2.0 - 0.01,
        );

        // movement
        const fwd = self.player_controller.forward();
        const rgt = self.player_controller.right();
        const spd = self.player_controller.speed * dt;

        if (input.isDown(core.bindings.sdl_usage.KeyCode.W)) self.eye = self.eye.add(fwd.mul(spd));
        if (input.isDown(core.bindings.sdl_usage.KeyCode.S)) self.eye = self.eye.sub(fwd.mul(spd));
        if (input.isDown(core.bindings.sdl_usage.KeyCode.A)) self.eye = self.eye.sub(rgt.mul(spd));
        if (input.isDown(core.bindings.sdl_usage.KeyCode.D)) self.eye = self.eye.add(rgt.mul(spd));

        self.target = self.eye.add(fwd);
    }

    var ubo = switch (self.mode) {
        .rotate_around => AllocatedData.GPUData{
            .view = Mat4.lookAt(eye, Vec3.ZERO, Vec3.UP),
            .proj = Mat4.perspective(self.fov, aspect, self.near_plane, self.far_plane),
        },
        .user_input => AllocatedData.GPUData{
            .view = Mat4.lookAt(self.eye, Vec3.ZERO, Vec3.UP),
            .proj = Mat4.perspective(self.fov, aspect, self.near_plane, self.far_plane),
        },
        .player => AllocatedData.GPUData{
            .view = Mat4.lookAt(self.eye, self.target, Vec3.UP),
            .proj = Mat4.perspective(self.fov, aspect, self.near_plane, self.far_plane),
        },
    };

    ubo.proj.j.y *= -1;

    const aligned_camera: *AllocatedData.GPUData = @ptrCast(@alignCast(camera_uniform.mapped));
    aligned_camera.* = ubo;
}
