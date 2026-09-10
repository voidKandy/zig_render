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

pipeline_description: ComputePipeline.Description,
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
    pd: ComputePipeline.Description,
};

pub fn init(
    a: std.mem.Allocator,
    ci: CreateInfo,
) std.mem.Allocator.Error!@This() {
    var maze = try core.lib.Maze.init(a, ci.push_constants.width, ci.push_constants.height);
    maze.generate(ci.push_constants.threshold, ci.push_constants.seed);
    const cells =
        try GPUMazeCell.arrayFromCellArray(a, maze.cells);

    return .{
        .maze = maze,
        .maze_gpu_cells = cells,
        .push_constants = ci.push_constants,
        .pipeline_description = ci.pd,
    };
}

pub fn initPipeline(
    self: *@This(),
    resources: core.resources.Manager,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    self.pipeline =
        ComputePipeline.init(self.pipeline_description, resources, alloc_cbs);
}

pub fn deinit(self: *@This(), a: std.mem.Allocator, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
    self.maze.deinit(a);
    a.free(self.maze_gpu_cells);
    self.pipeline.deinit(device, alloc_cbs);
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

pub fn addCreateData(self: @This(), a: std.mem.Allocator, resources: *core.resources.Manager) std.mem.Allocator.Error!void {
    try resources.mapped_buffers.creates.put(
        a,
        MAZE_RESOURCE_NAME,

        .{
            .alloc_size = @sizeOf(GPUMazeCell) * self.maze.width * self.maze.height,
            .buffer_usage = vk.BUFFER_USAGE_STORAGE_BUFFER_BIT,
            .mem_usage = core.clibs.vma.MEMORY_USAGE_CPU_TO_GPU,
            .flags = 0,
        },
    );

    try resources.materials.textures.put(
        a,
        MAZE_RESOURCE_NAME,
        .{
            .extent = vk.Extent3D{
                .width = self.maze.width * self.push_constants.pixels_per_cell,
                .height = self.maze.height * self.push_constants.pixels_per_cell,
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
            // .sampler_ci = vk.SamplerCreateInfo{
            //     .sType = vk.STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            //     .magFilter = vk.FILTER_NEAREST,
            //     .minFilter = vk.FILTER_NEAREST,
            //     .addressModeU = vk.SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            //     .addressModeV = vk.SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            //     .addressModeW = vk.SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            // },
        },
    );
}

pub fn trySyncResources(self: *@This(), alloc_resources: core.resources.Manager.AllocatedData) void {
    if (self.needs_gpu_sync) {
        const aligned_maze: [*]GPUMazeCell = @ptrCast(
            @alignCast(alloc_resources.mapped_buffers.buffers.get(MAZE_RESOURCE_NAME).?.mapped),
        );
        @memcpy(aligned_maze, self.maze_gpu_cells);
        self.needs_gpu_sync = false;
    }
}

pub fn update(
    self: *@This(),
) void {
    if (self.maze_update) {
        for (self.maze.cells) |*c|
            c.walls = .{};

        self.maze.generate(self.maze.threshold.?, self.maze.seed.?);

        GPUMazeCell.convertCells(self.maze.cells, &self.maze_gpu_cells);

        self.maze_update = false;
        self.needs_gpu_sync = true;
    }
}

pub fn drawImgui(
    self: *@This(),
    // ui_set: core.clibs.vk.DescriptorSet,
) void {
    var open = true;
    const shown = imgui.Begin("Maze", &open, core.clibs.imgui.WINDOW_ALWAYS_AUTO_RESIZE);
    var seed: c_int = @intCast(self.maze.seed.?);
    if (imgui.InputInt("seed", &seed)) {
        self.maze.seed = @as(u64, @intCast(seed));
        self.maze_update = true;
    }
    defer imgui.End();
    if (!shown) return;
    // imgui.Image(ui_set, imgui.ImVec2{ .x = 400, .y = 400 });
}

const ComputePipeline = struct {
    pipeline: vk.Pipeline = undefined,
    pipeline_layout: vk.PipelineLayout = undefined,

    /// TODO
    /// remove device from this
    pub const Description = struct {
        camera_descriptor_set_layout_name: []const u8,
        device: vk.Device,
    };

    pub fn deinit(self: *@This(), device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
        vk.DestroyPipeline(device, self.pipeline, alloc_cbs);
        vk.DestroyPipelineLayout(device, self.pipeline_layout, alloc_cbs);
    }

    pub fn init(
        pd: Description,
        // resources is only passed here so the function can grab the descriptor sets for this given system
        // there is opportunity for abstraction here
        resources: core.resources.Manager,
        alloc_cbs: ?*vk.AllocationCallbacks,
    ) @This() {
        var self = @This(){};
        const maze_shader = core.engine.shaders.createShaderModule(
            "maze.comp",
            pd.device,
            alloc_cbs,
        ) orelse @panic("failed to create maze compute shader module");
        defer vk.DestroyShaderModule(pd.device, maze_shader, alloc_cbs);
        const push_constant = vk.PushConstantRange{
            .offset = 0,
            .size = @sizeOf(PushConstants),
            .stageFlags = vk.SHADER_STAGE_COMPUTE_BIT,
        };

        const camera_layout = resources.mapped_buffers.buffer_set_layouts.get(pd.camera_descriptor_set_layout_name).?.layout;
        const texture_write_layout = resources.materials.writable_textures_descriptor_set_layouts.get(COMPUTE_MAZE_SET_NAME).?.layout;
        const mapped_buffer_layout = resources.mapped_buffers.buffer_set_layouts.get(COMPUTE_MAZE_SET_NAME).?.layout;

        const set_layouts = [_]vk.DescriptorSetLayout{
            camera_layout,
            texture_write_layout,
            mapped_buffer_layout,
        };

        const layout_ci = vk.PipelineLayoutCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .setLayoutCount = set_layouts.len,
            .pSetLayouts = &set_layouts,
            .pushConstantRangeCount = 1,
            .pPushConstantRanges = &push_constant,
        };
        checkVk(vk.CreatePipelineLayout(pd.device, &layout_ci, alloc_cbs, &self.pipeline_layout)) catch
            @panic("failed to create main compute pipeline layout");

        const stage = vk.PipelineShaderStageCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = vk.SHADER_STAGE_COMPUTE_BIT,
            .module = maze_shader,
            .pName = "main",
        };
        const ci = vk.ComputePipelineCreateInfo{
            .sType = vk.STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
            .layout = self.pipeline_layout,
            .stage = stage,
        };
        checkVk(vk.CreateComputePipelines(pd.device, null, 1, &ci, alloc_cbs, &self.pipeline)) catch
            @panic("failed to create main compute pipeline");

        return self;
    }

    pub fn bind(self: @This(), cmd: vk.CommandBuffer) void {
        vk.CmdBindPipeline(cmd, vk.PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
    }

    pub fn recordCommands(
        self: @This(),
        alloc_resources: core.resources.Manager.AllocatedData,
        camera_descriptor_set: vk.DescriptorSet,
        write_texture_set: vk.DescriptorSet,
        mapped_buffer_set: vk.DescriptorSet,
        maze_system: core.engine.systems.Maze,
        cmd: vk.CommandBuffer,
    ) void {
        const sets = [_]vk.DescriptorSet{ camera_descriptor_set, write_texture_set, mapped_buffer_set };
        vk.CmdBindDescriptorSets(
            cmd,
            vk.PIPELINE_BIND_POINT_COMPUTE,
            self.pipeline_layout,
            0,
            sets.len,
            &sets,
            0,
            null,
        );

        vk.CmdPushConstants(
            cmd,
            self.pipeline_layout,
            vk.SHADER_STAGE_COMPUTE_BIT,
            0,
            @sizeOf(core.engine.systems.Maze.PushConstants),
            &maze_system.push_constants,
        );

        const maze_image = alloc_resources.materials.textures.get(MAZE_RESOURCE_NAME).?;

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
        const w: u32 = @intFromFloat(std.math.ceil(@as(f32, @floatFromInt(maze_system.maze.width * maze_system.push_constants.pixels_per_cell)) / 8.0));
        const h: u32 = @intFromFloat(std.math.ceil(@as(f32, @floatFromInt(maze_system.maze.height * maze_system.push_constants.pixels_per_cell)) / 8.0));
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
};
