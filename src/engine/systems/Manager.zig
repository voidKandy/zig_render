const std = @import("std");
const core = @import("../../root.zig");
const log = std.log.scoped(.SystemManager);
const vk = core.clibs.vk;
pub const MeshManipulation = @import("./MeshManipulation.zig");
pub const Maze = @import("./Maze.zig");
pub const Debug = @import("./Debug.zig");
pub const Camera = @import("./Camera.zig");
pub const DrawBackground = @import("./DrawBackground.zig");

// down the line some kind of container abstraction might be good for individual systems, but
// for now they will all just exist as explicit fields
mesh_manipulation: MeshManipulation,
maze: Maze,
camera: Camera,
draw_background: DrawBackground,
debug: Debug,

pub fn init(
    a: std.mem.Allocator,
    swapchain_extent: vk.Extent2D,
    maze_system_ci: core.engine.systems.Maze.CreateInfo,
) @This() {
    return .{
        .mesh_manipulation = .{},
        .maze = Maze.init(a, maze_system_ci) catch @panic("failed to create maze system"),
        .debug = .{},
        .camera = Camera.init(.{}, swapchain_extent) catch @panic("failed to create camera system"),
        .draw_background = DrawBackground.init(swapchain_extent),
    };
}

pub fn deinit(
    self: *@This(),
    allocs: core.engine.Allocators,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    self.mesh_manipulation.deinit(allocs);
    self.maze.deinit(allocs.std, device, alloc_cbs);
    self.debug.deinit(allocs.std);
    self.draw_background.deinit(device, alloc_cbs);
}

pub fn registerSets(
    _: @This(),
    a: std.mem.Allocator,
    device: vk.Device,
    resources: *core.resources.Manager,
    alloc_cbs: ?*vk.AllocationCallbacks,
) std.mem.Allocator.Error!void {
    try Maze.registerSets(a, device, resources, alloc_cbs);
    try Camera.registerSets(a, device, resources, alloc_cbs);
    try DrawBackground.registerSets(a, device, resources, alloc_cbs);
}

/// wasnt sure what to call this
/// currently only Debug has a need for access to
/// resources after they are created but im sure this
/// will change
pub fn bind(
    self: *@This(),
    a: std.mem.Allocator,
    alloc_resources: core.resources.Manager.AllocatedData,
) void {
    self.debug.bind(a, alloc_resources) catch @panic("OOM");
}

pub fn update(self: *@This(), engine: core.engine.Engine) void {
    self.camera.update(engine);
    self.maze.update();
}

pub fn initComputePipelines(
    self: *@This(),
    device: vk.Device,
    resources: core.resources.Manager,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    self.maze.initPipeline(resources, alloc_cbs);
    self.draw_background.initPipeline(device, resources, alloc_cbs);
}

pub fn trySyncResources(
    self: *@This(),
    resources: core.resources.Manager,
    allocated_resources: core.resources.Manager.AllocatedData,
    world: *core.engine.world.GameWorld,
) void {
    self.maze.trySyncResources(allocated_resources);
    self.mesh_manipulation.trySyncResources(resources, allocated_resources, world);
    self.camera.trySyncResources(allocated_resources);
}

pub fn addCreateData(self: @This(), a: std.mem.Allocator, resources: *core.resources.Manager) std.mem.Allocator.Error!void {
    try self.maze.addCreateData(a, resources);
    try self.camera.addCreateData(a, resources);
    try self.draw_background.addCreateData(a, resources);
}

pub fn drawImgui(self: *@This(), engine: *core.engine.Engine) void {
    self.debug.drawImgui(engine.window);
    self.camera.drawImgui();
    self.draw_background.drawImgui();
    self.maze.drawImgui();
    self.mesh_manipulation.drawImgui(
        engine.allocs.std,
        &engine.mesh3D_pipeline,
        &engine.world,
        engine.resources,
        engine.allocated_resources,
    );
}

pub fn recordComputeCommands(
    self: @This(),
    engine: core.engine.Engine,
    cmd: vk.CommandBuffer,
    framebuffer_idx: u32,
) void {
    self.maze.pipeline.bind(cmd);
    self.maze.pipeline.recordCommands(
        engine.allocated_resources,
        engine.allocated_resources.mapped_buffers.buffer_sets.get(Camera.CAMERA_SET_NAME).?.set,
        engine.allocated_resources.materials.writable_textures_descriptor_sets.get(Maze.COMPUTE_MAZE_SET_NAME).?.set,
        engine.allocated_resources.mapped_buffers.buffer_sets.get(Maze.COMPUTE_MAZE_SET_NAME).?.set,
        self.maze,
        cmd,
    );

    self.draw_background.pipeline.bind(cmd);
    self.draw_background.pipeline.recordCommands(
        engine.allocated_resources,
        engine.swapchain,
        framebuffer_idx,
        engine.allocated_resources.materials.writable_textures_descriptor_sets.get(DrawBackground.BACKGROUND_SET_NAME).?.set,
        cmd,
    );
}
