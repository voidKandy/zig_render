const std = @import("std");
const core = @import("../../root.zig");
const log = std.log.scoped(.MazeSystem);
const imgui = core.clibs.imgui;
const vk = core.clibs.vk;
const checkVk = core.bindings.vulkan_init.checkVk;

maze: core.lib.Maze,
maze_gpu_cells: []GPUMazeCell,
push_constants: PushConstants,
maze_update: bool = false,
needs_gpu_sync: bool = true,
/// not currently working because meshes3D is not dynamic
update_mesh: bool = false,

mesh3D_id: u32,
mesh2D_id: u32,

// pipeline_description: ComputePipeline.Description,
pipeline: ComputePipeline = undefined,

pub const COMPUTE_MAZE_SET_NAME = "compute_maze_set";
pub const MAZE_RESOURCE_NAME = "maze";

pub const PushConstants = extern struct {
    width: u32,
    height: u32,
    pixels_per_cell: u32,
    /// size of maze mesh cells in world scale
    cell_size: f32,
    maze_origin: core.lib.math.Vec3,
    seed: u32,
    threshold: usize,
};

pub const GPUMazeCell = extern struct {
    walls: u32,

    /// mutates a pre-allocated array of gpucells
    fn convertCells(arr: []core.lib.Maze.Cell, self_arr: *[]@This()) void {
        @memset(self_arr.*, .{
            .walls = 0,
        });
        for (arr, 0..) |item, i| {
            self_arr.*[i].walls =
                (@as(u32, @intFromBool(item.walls.north)) << 0) |
                (@as(u32, @intFromBool(item.walls.south)) << 1) |
                (@as(u32, @intFromBool(item.walls.east)) << 2) |
                (@as(u32, @intFromBool(item.walls.west)) << 3);
        }
    }

    fn arrayFromCellArray(a: std.mem.Allocator, arr: []core.lib.Maze.Cell) std.mem.Allocator.Error![]@This() {
        var all = try a.alloc(GPUMazeCell, arr.len);
        for (arr, 0..) |item, i| {
            all[i].walls =
                (@as(u32, @intFromBool(item.walls.north)) << 0) |
                (@as(u32, @intFromBool(item.walls.south)) << 1) |
                (@as(u32, @intFromBool(item.walls.east)) << 2) |
                (@as(u32, @intFromBool(item.walls.west)) << 3);
        }
        return all;
    }
};

pub const CreateInfo = struct {
    push_constants: PushConstants,
    mesh_options: core.lib.Maze.MeshOptions,
};

pub fn init(
    a: std.mem.Allocator,
    world: *core.engine.world.GameWorld,
    resources: *core.resources.Manager,
    ci: CreateInfo,
) std.mem.Allocator.Error!@This() {
    var maze = try core.lib.Maze.init(a, ci.push_constants.width, ci.push_constants.height);
    maze.generate(ci.push_constants.threshold, ci.push_constants.seed);
    const cells =
        try GPUMazeCell.arrayFromCellArray(a, maze.cells);

    try resources.mapped_buffers.creates.put(
        a,
        MAZE_RESOURCE_NAME,

        .{
            .alloc_size = @sizeOf(GPUMazeCell) * maze.width * maze.height,
            .buffer_usage = vk.BUFFER_USAGE_STORAGE_BUFFER_BIT,
            .mem_usage = core.clibs.vma.MEMORY_USAGE_CPU_TO_GPU,
            .flags = 0,
        },
    );

    try resources.materials.appendWritableTexture(
        a,
        MAZE_RESOURCE_NAME,
        .{
            .extent = vk.Extent3D{
                .width = maze.width * ci.push_constants.pixels_per_cell,
                .height = maze.height * ci.push_constants.pixels_per_cell,
                .depth = 1,
            },
            .format = vk.FORMAT_R8G8B8A8_UNORM,
            .usages = vk.IMAGE_USAGE_STORAGE_BIT |
                vk.IMAGE_USAGE_SAMPLED_BIT |
                vk.IMAGE_USAGE_TRANSFER_DST_BIT,
            .aspect_flags = vk.IMAGE_ASPECT_COLOR_BIT,
            .initial_transition_function = &struct {
                pub fn submit(
                    device: core.bindings.vulkan_init.LogicalDevice,
                    upload_ctx: *core.bindings.vulkan_init.UploadContext,
                    img: vk.Image,
                ) void {
                    upload_ctx.immediateSubmit(device, struct {
                        img: vk.Image,
                        pub fn submit(this: @This(), cmd_buf: vk.CommandBuffer) void {
                            core.bindings.vulkan_util.transitionImageLayout(
                                cmd_buf,
                                this.img,
                                vk.IMAGE_LAYOUT_UNDEFINED,
                                vk.IMAGE_LAYOUT_GENERAL,
                                0,
                                vk.ACCESS_SHADER_WRITE_BIT,
                                vk.PIPELINE_STAGE_TOP_OF_PIPE_BIT,
                                vk.PIPELINE_STAGE_COMPUTE_SHADER_BIT,
                            );
                        }
                    }{ .img = img });
                }
            }.submit,
        },
    );

    const mt_idx = resources.materials.material_indices.get(MAZE_RESOURCE_NAME).?;

    const maze_mesh3D = ci.mesh_options.createMesh(a, maze) catch @panic("failed to create 3D maze mesh");
    defer maze_mesh3D.deinit(a);
    try resources.meshes3D.appendMesh(a, MAZE_RESOURCE_NAME, maze_mesh3D);
    // resources.meshes3D.appendMeshWithMaterialIndex(
    //     a,
    //     maze_mesh3D,
    //     .IDENTITY,
    //     0,
    // ) catch @panic("OOM");

    var mesh3d_entity = try world.entities.register(null);
    mesh3d_entity.addComponent(.mesh3D, core.engine.world.MaterialMesh3D{
        .mesh_index = @intCast(resources.meshes3D.meshes.items.len - 1),
        .material_index = @intCast(mt_idx),
    });

    const margin: f32 = 0.05;
    const quad_size = 0.2;
    const maze_quad = core.lib.mesh.Mesh2D.ndcQuad(a, quad_size, quad_size) catch @panic("failed to create maze quad");
    defer maze_quad.deinit(a);
    const coordinates = core.lib.math.Vec2.make(
        1.0 - (quad_size / 2.0) - margin,
        1.0 - margin - quad_size,
    );

    resources.meshes2D.appendMesh(
        a,
        maze_quad,
        coordinates,
        @as(u32, @intCast(mt_idx)),
    ) catch @panic("OOM");

    var mesh2d_entity = try world.entities.register(null);
    mesh2d_entity.addComponent(.mesh2D, core.engine.world.Mesh2DComponent{
        .ranges = resources.meshes2D.ranges.getLast(),
    });

    return .{
        .maze = maze,
        .maze_gpu_cells = cells,
        .push_constants = ci.push_constants,
        // .pipeline_description = ci.pd,
        .mesh3D_id = mesh3d_entity.identifier,
        .mesh2D_id = mesh2d_entity.identifier,
    };
}

pub fn updateSets(
    device: vk.Device,
    allocated_resources: *core.resources.Manager.AllocatedData,
) void {
    allocated_resources.mapped_buffers.updateBufferSet(
        device,
        COMPUTE_MAZE_SET_NAME,
    );

    allocated_resources.materials.updateWritableTextureSet(
        device,
        COMPUTE_MAZE_SET_NAME,
    );
}

pub fn deinit(self: *@This(), allocs: core.engine.Allocators, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
    self.maze.deinit(allocs.std);
    allocs.std.free(self.maze_gpu_cells);
    self.pipeline.deinit(device, alloc_cbs);
}

pub fn initPipelines(
    self: *@This(),
    device: vk.Device,
    resources: core.resources.Manager,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const layouts = ComputePipeline.Description.Layouts.init(.{
        .camera = resources.mapped_buffers.buffer_set_layouts.get(core.engine.systems.Camera.CAMERA_SET_NAME).?.layout,
        .maze_texture = resources.materials.writable_textures_descriptor_set_layouts.get(COMPUTE_MAZE_SET_NAME).?.layout,
        .maze_buffer = resources.mapped_buffers.buffer_set_layouts.get(COMPUTE_MAZE_SET_NAME).?.layout,
    });

    self.pipeline = ComputePipeline.init(device, layouts, alloc_cbs);
}

pub fn registerSets(a: std.mem.Allocator, device: vk.Device, resources: *core.resources.Manager, alloc_cbs: ?*vk.AllocationCallbacks) std.mem.Allocator.Error!void {
    try resources.materials.createAndRegisterWritableTextureSetLayout(
        a,
        COMPUTE_MAZE_SET_NAME,
        &[_][]const u8{MAZE_RESOURCE_NAME},
        device,
        alloc_cbs,
    );

    try resources.mapped_buffers.createAndRegisterBufferSetLayout(
        a,
        COMPUTE_MAZE_SET_NAME,
        &[_]core.resources.MappedBuffers.CreateBufferInfo{
            .{
                .name = MAZE_RESOURCE_NAME,
                .descriptor_type = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
                .binding = 0,
                .stage_flags = vk.SHADER_STAGE_COMPUTE_BIT,
            },
        },
        device,
        alloc_cbs,
    );
}

pub fn trySyncResources(self: *@This(), alloc_resources: core.resources.Manager.AllocatedData) void {
    if (self.needs_gpu_sync) {
        const aligned_maze: [*]GPUMazeCell = @ptrCast(
            @alignCast(alloc_resources.mapped_buffers.buffers.get(MAZE_RESOURCE_NAME).?.mapped),
        );
        @memcpy(aligned_maze, self.maze_gpu_cells);
        self.needs_gpu_sync = false;

        // alloc_resources.meshes3D.vertex_buffer
        // add check for 3d or 2d gpu sync
        // const aligned_maze_mesh = @ptrCast();
    }
}

pub fn update(
    self: *@This(),
    _: f32,
    _: core.engine.Input,
    _: *core.engine.world.GameWorld,
) void {
    if (self.maze_update) {
        for (self.maze.cells) |*c|
            c.walls = .{};

        self.maze.generate(self.maze.threshold.?, self.maze.seed.?);

        GPUMazeCell.convertCells(self.maze.cells, &self.maze_gpu_cells);

        self.maze_update = false;
        self.needs_gpu_sync = true;
    }

    // if (self.update_mesh) {
    //     const maze_mesh3D = self.mesh_options.createMesh(a, maze) catch @panic("failed to create 3D maze mesh");
    // }
}

pub fn recordComputeCommands(
    self: @This(),
    allocated_resources: core.resources.Manager.AllocatedData,
    _: core.bindings.vulkan_init.Swapchain,
    cmd: vk.CommandBuffer,
    _: u32,
) void {
    self.pipeline.bind(cmd);
    const sets = [_]vk.DescriptorSet{
        allocated_resources.mapped_buffers.buffer_sets.get(core.engine.systems.Camera.CAMERA_SET_NAME).?.set,
        allocated_resources.materials.writable_textures_descriptor_sets.get(COMPUTE_MAZE_SET_NAME).?.set,
        allocated_resources.mapped_buffers.buffer_sets.get(COMPUTE_MAZE_SET_NAME).?.set,
    };
    vk.CmdBindDescriptorSets(
        cmd,
        vk.PIPELINE_BIND_POINT_COMPUTE,
        self.pipeline.layout,
        0,
        sets.len,
        &sets,
        0,
        null,
    );

    vk.CmdPushConstants(
        cmd,
        self.pipeline.layout,
        vk.SHADER_STAGE_COMPUTE_BIT,
        0,
        @sizeOf(PushConstants),
        &self.push_constants,
    );

    const maze_image = allocated_resources.materials.textures.get(MAZE_RESOURCE_NAME).?;

    // transition to GENERAL for compute write
    core.bindings.vulkan_util.transitionImageLayout(
        cmd,
        maze_image.image,
        vk.IMAGE_LAYOUT_UNDEFINED,
        vk.IMAGE_LAYOUT_GENERAL,
        0,
        vk.ACCESS_SHADER_WRITE_BIT,
        vk.PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        vk.PIPELINE_STAGE_COMPUTE_SHADER_BIT,
    );
    const w: u32 = @intFromFloat(std.math.ceil(@as(f32, @floatFromInt(self.maze.width * self.push_constants.pixels_per_cell)) / 8.0));
    const h: u32 = @intFromFloat(std.math.ceil(@as(f32, @floatFromInt(self.maze.height * self.push_constants.pixels_per_cell)) / 8.0));
    vk.CmdDispatch(cmd, w, h, 1);

    // transition to SHADER_READ_ONLY so HUD can sample it
    core.bindings.vulkan_util.transitionImageLayout(
        cmd,
        maze_image.image,
        vk.IMAGE_LAYOUT_GENERAL,
        vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        vk.ACCESS_SHADER_WRITE_BIT,
        vk.ACCESS_SHADER_READ_BIT,
        vk.PIPELINE_STAGE_COMPUTE_SHADER_BIT,
        vk.PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
    );
}

pub fn drawImgui(self: *@This(), _: core.engine.systems.manager.DrawImguiContext) void {
    var open = true;
    const shown = imgui.Begin("Maze", &open, core.clibs.imgui.WINDOW_ALWAYS_AUTO_RESIZE);
    var seed: c_int = @intCast(self.maze.seed.?);
    if (imgui.InputInt("seed", &seed)) {
        self.maze.seed = @as(u64, @intCast(seed));
        self.maze_update = true;
    }

    if (imgui.Button(
        "Recreate mesh?",
    )) self.update_mesh = true;

    defer imgui.End();
    if (!shown) return;
    // imgui.Image(ui_set, imgui.ImVec2{ .x = 400, .y = 400 });
}

const ComputePipeline = struct {
    pipeline: vk.Pipeline = undefined,
    layout: vk.PipelineLayout = undefined,

    const Description = core.engine.graphics_pipelines.Description(
        .{
            .Enum = enum {
                camera,
                maze_texture,
                maze_buffer,
            },
            .push_constants = .{
                PushConstants,
                vk.SHADER_STAGE_COMPUTE_BIT,
            },
        },
    );

    pub fn deinit(self: *@This(), device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
        vk.DestroyPipeline(device, self.pipeline, alloc_cbs);
        vk.DestroyPipelineLayout(device, self.layout, alloc_cbs);
    }

    pub fn init(
        device: vk.Device,
        layouts: Description.Layouts,
        alloc_cbs: ?*vk.AllocationCallbacks,
    ) @This() {
        var self = @This(){};
        const maze_shader = core.engine.shaders.createShaderModule(
            "maze.comp",
            device,
            alloc_cbs,
        ) orelse @panic("failed to create maze compute shader module");
        defer vk.DestroyShaderModule(device, maze_shader, alloc_cbs);

        self.layout = Description.createPipelineLayout(layouts, device, alloc_cbs);

        const stage = vk.PipelineShaderStageCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = vk.SHADER_STAGE_COMPUTE_BIT,
            .module = maze_shader,
            .pName = "main",
        };
        const ci = vk.ComputePipelineCreateInfo{
            .sType = vk.STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
            .layout = self.layout,
            .stage = stage,
        };
        checkVk(vk.CreateComputePipelines(device, null, 1, &ci, alloc_cbs, &self.pipeline)) catch
            @panic("failed to create main compute pipeline");

        return self;
    }

    fn bind(self: @This(), cmd: vk.CommandBuffer) void {
        vk.CmdBindPipeline(cmd, vk.PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
    }
};
