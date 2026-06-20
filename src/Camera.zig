const std = @import("std");
const core = @import("root.zig");
const c = core.clibs;
const vk = c.vk;
const vki = core.vulkan_init;
const checkVk = vki.checkVk;
const Vec3 = core.math.Vec3;
const Mat4 = core.math.Mat4;

pub const GPUData = struct {
    view: Mat4,
    proj: Mat4,
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

pub fn createGPUData(self: @This(), extent: vk.Extent2D) GPUData {
    const aspect =
        @as(f32, @floatFromInt(extent.width)) /
        @as(f32, @floatFromInt(extent.height));

    return core.Camera.GPUData{
        .view = core.math.Mat4.lookAt(
            self.eye,
            self.target,
            // core.math.Vec3.ZERO,
            core.math.Vec3.UP,
        ),
        .proj = core.math.Mat4.perspective(
            self.fov,
            aspect,
            self.near_plane,
            self.far_plane,
        ),
    };
}

pub fn control(
    self: *@This(),
    camera_uniform: core.vma_usage.MappedBuffer,
    input: core.Input,
    screen_extent: vk.Extent2D,
) void {
    const State = struct {
        var start: i128 = 0;
        var yaw: f32 = 0.0;
        var last_time: i128 = 0;
    };
    if (State.start == 0) {
        State.start = std.time.nanoTimestamp();
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

    const now = std.time.nanoTimestamp();
    const dt: f32 = @as(f32, @floatFromInt(now - State.last_time)) / @as(f32, @floatFromInt(std.time.ns_per_s));
    State.last_time = now;

    const delta_ns = now - State.start;
    const time: f32 = @as(f32, (@floatFromInt(delta_ns))) / @as(f32, (@floatFromInt(std.time.ns_per_s)));
    State.yaw = time * 1.0;

    const aspect =
        @as(f32, @floatFromInt(screen_extent.width)) /
        @as(f32, @floatFromInt(screen_extent.height));

    const eye = core.math.Vec3.make(
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

        if (input.isDown(core.sdl_usage.KeyCode.W)) self.eye = self.eye.add(fwd.mul(spd));
        if (input.isDown(core.sdl_usage.KeyCode.S)) self.eye = self.eye.sub(fwd.mul(spd));
        if (input.isDown(core.sdl_usage.KeyCode.A)) self.eye = self.eye.sub(rgt.mul(spd));
        if (input.isDown(core.sdl_usage.KeyCode.D)) self.eye = self.eye.add(rgt.mul(spd));

        self.target = self.eye.add(fwd);
    }

    var ubo = switch (self.mode) {
        .rotate_around => core.Camera.GPUData{
            .view = core.math.Mat4.lookAt(eye, core.math.Vec3.ZERO, core.math.Vec3.UP),
            .proj = core.math.Mat4.perspective(self.fov, aspect, self.near_plane, self.far_plane),
        },
        .user_input => core.Camera.GPUData{
            .view = core.math.Mat4.lookAt(self.eye, core.math.Vec3.ZERO, core.math.Vec3.UP),
            .proj = core.math.Mat4.perspective(self.fov, aspect, self.near_plane, self.far_plane),
        },
        .player => core.Camera.GPUData{
            .view = core.math.Mat4.lookAt(self.eye, self.target, core.math.Vec3.UP),
            .proj = core.math.Mat4.perspective(self.fov, aspect, self.near_plane, self.far_plane),
        },
    };

    ubo.proj.j.y *= -1;

    const aligned_camera: *core.Camera.GPUData = @ptrCast(@alignCast(camera_uniform.mapped));
    aligned_camera.* = ubo;
}
