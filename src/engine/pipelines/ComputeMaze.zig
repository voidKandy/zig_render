const std = @import("std");
const mem = std.mem;
const core = @import("../../root.zig");
const imgui = core.clibs.imgui;
const log = std.log.scoped(.ComputeMaze);
const vki = core.bindings.vulkan_init;
const vk = core.clibs.vk;
const vma_usage = core.bindings.vma_usage;
const checkVk = vki.checkVk;

pub const Description = struct {
    camera_descriptor_set_layout: vk.DescriptorSetLayout,
    texture_set_layout: vk.DescriptorSetLayout,
    meshes_set_layout: vk.DescriptorSetLayout,
    device: vk.Device,
    render_pass: vk.RenderPass,
    window_extent: vk.Extent2D,
};

pipeline: vk.Pipeline = undefined,
pipeline_layout: vk.PipelineLayout = undefined,
// mapped_buffer_descriptor_set_layout: vk.DescriptorSetLayout = undefined,
// texture_write_descriptor_set_layout: vk.DescriptorSetLayout = undefined,

const Self = @This();

pub fn deinit(self: *Self, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
    vk.DestroyPipeline(device, self.pipeline, alloc_cbs);
    vk.DestroyPipelineLayout(device, self.pipeline_layout, alloc_cbs);
    // vk.DestroyDescriptorSetLayout(device, self.mapped_buffer_descriptor_set_layout, alloc_cbs);
    // vk.DestroyDescriptorSetLayout(device, self.texture_write_descriptor_set_layout, alloc_cbs);
}

// WARNING
// if additional writes need to be added this is where
// this is very fragile and not well tested so adding something
// here may break the implementation. Namely, in the shader code
/// A single isntance of this expects the engine to have
/// both a `texture` and a `mapped_buffer` with a name matching the enum variant
const TextureBufferPair = enum {
    maze,
};

pub fn init(
    pd: Description,
    resources: core.resources.Manager,
    alloc_cbs: ?*vk.AllocationCallbacks,
) Self {
    var self = Self{};
    // self.createDescriptorSetLayout(pd.device, resources, alloc_cbs);
    // self.texture_write_descriptor_set_layout = resources.materials.createWritableTextureSetLayout(
    //     std.meta.fieldNames(TextureBufferPair),
    //     pd.device,
    //     alloc_cbs,
    // );
    self.initPipeline(pd, resources, alloc_cbs);
    return self;
}

// fn createDescriptorSetLayout(
//     self: *Self,
//     device: vk.Device,
//     resources: core.resources.Manager,
//     alloc_cbs: ?*vk.AllocationCallbacks,
// ) void {
//     var bindings: [std.meta.tags(TextureBufferPair).len]vk.DescriptorSetLayoutBinding = undefined;
//     var i: usize = 0;
//     for (std.meta.tags(TextureBufferPair)) |tag| {
//         const binding = resources.mapped_buffers.createDescriptorSetLayoutBinding(
//             @tagName(tag),
//             @intFromEnum(tag),
//             vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
//             vk.SHADER_STAGE_COMPUTE_BIT,
//         );
//         bindings[i] = binding;
//         i += 1;
//     }

//     const ci = vk.DescriptorSetLayoutCreateInfo{
//         .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
//         .bindingCount = @as(u32, @intCast(i)),
//         .pBindings = bindings[0..i].ptr,
//     };
//     checkVk(vk.CreateDescriptorSetLayout(device, &ci, alloc_cbs, &self.mapped_buffer_descriptor_set_layout)) catch
//         @panic("failed to create main compute descriptor set layout");
// }

fn initPipeline(
    self: *Self,
    pd: Description,
    resources: core.resources.Manager,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    // TODO
    // it follows that each TextureBufferPair will need its own shader code
    // for using the buffer in whatever way is necessary to write to a texture
    const maze_shader = core.engine.shaders.createShaderModule(
        "maze.comp",
        pd.device,
        alloc_cbs,
    ) orelse @panic("failed to create maze compute shader module");
    defer vk.DestroyShaderModule(pd.device, maze_shader, alloc_cbs);
    // also, each TextureBufferPair will likely need it's own push consstant type
    // associated with it
    const push_constant = vk.PushConstantRange{
        .offset = 0,
        .size = @sizeOf(core.engine.systems.Maze.PushConstants),
        .stageFlags = vk.SHADER_STAGE_COMPUTE_BIT,
    };

    const texture_write_layout = resources.materials.writable_textures_descriptor_set_layouts.get(core.engine.systems.Maze.COMPUTE_MAZE_SET_NAME).?.layout;
    const mapped_buffer_layout = resources.mapped_buffers.buffer_set_layouts.get(core.engine.systems.Maze.COMPUTE_MAZE_SET_NAME).?.layout;

    const set_layouts = [_]vk.DescriptorSetLayout{
        pd.camera_descriptor_set_layout,
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
}

// pub const DescriptorSets = struct {
//     mapped_buffer: vk.DescriptorSet,
//     write_texture: vk.DescriptorSet,
//     ui: vk.DescriptorSet,
// };

// pub fn allocateDescriptorSets(
//     self: Self,
//     pool: vk.DescriptorPool,
//     device: vk.Device,
//     alloc_resources: core.resources.Manager.AllocatedData,
// ) DescriptorSets {
//     var mapped_buffer_set: vk.DescriptorSet = undefined;
//     const mp_bf_ai = vk.DescriptorSetAllocateInfo{
//         .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
//         .descriptorPool = pool,
//         .descriptorSetCount = 1,
//         .pSetLayouts = &self.mapped_buffer_descriptor_set_layout,
//     };

//     log.debug(
//         "allocating descriptor set with layout = {*}\n",
//         .{self.mapped_buffer_descriptor_set_layout},
//     );

//     checkVk(vk.AllocateDescriptorSets(
//         device,
//         &mp_bf_ai,
//         &mapped_buffer_set,
//     )) catch
//         @panic("failed to allocate mapped buffer descriptor set");

//     var write_texture_set: vk.DescriptorSet = undefined;
//     const wr_tx_ai = vk.DescriptorSetAllocateInfo{
//         .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
//         .descriptorPool = pool,
//         .descriptorSetCount = 1,
//         .pSetLayouts = &self.texture_write_descriptor_set_layout,
//     };

//     checkVk(vk.AllocateDescriptorSets(
//         device,
//         &wr_tx_ai,
//         &write_texture_set,
//     )) catch |e|
//         std.debug.panic("failed to allocate writable-texture descriptor set: {s}", .{@errorName(e)});

//     // TODO
//     // some kind of system that adds all textures to the ui set
//     // example:
//     // for (std.meta.tags(TextureBufferPair)) |tag| {
//     // const tex = alloc_resources.materials.textures.get(@tagName(tag)).?;
//     // const ui_set = imgui.impl_vulkan.AddTexture(maze_tex.sampler, maze_tex.image_alloc.view, vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);
//     // }

//     const maze_tex = alloc_resources.materials.textures.get(core.engine.systems.Maze.MAZE_RESOURCE_NAME).?;
//     const ui_set = imgui.impl_vulkan.AddTexture(maze_tex.sampler, maze_tex.image_alloc.view, vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL);

//     return .{
//         .mapped_buffer = mapped_buffer_set,
//         .write_texture = write_texture_set,
//         .ui = ui_set,
//     };
// }

// pub fn updateDescriptorSets(
//     device: vk.Device,
//     alloc_resources: core.resources.Manager.AllocatedData,
//     sets: DescriptorSets,
// ) void {
//     alloc_resources.materials.updateWritableTextureSet(
//         device,
//         sets.write_texture,
//         std.meta.fieldNames(TextureBufferPair),
//     );

//     var writes: [std.meta.tags(TextureBufferPair).len]vk.WriteDescriptorSet = undefined;

//     var i: usize = 0;
//     for (std.meta.tags(TextureBufferPair)) |tag| {
//         var buf_info: vk.DescriptorBufferInfo = undefined;
//         writes[i] =
//             alloc_resources.mapped_buffers.createDescriptorSetWrite(
//                 sets.mapped_buffer,
//                 @tagName(tag),
//                 @intFromEnum(tag),
//                 @as(u32, @intCast(i)),
//                 vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
//                 &buf_info,
//             );
//         i += 1;
//     }

//     vk.UpdateDescriptorSets(device, @as(u32, @intCast(i)), writes[0..i].ptr, 0, null);
// }

pub fn bind(self: Self, cmd: vk.CommandBuffer) void {
    vk.CmdBindPipeline(cmd, vk.PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
}

pub fn recordCommands(
    self: Self,
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

    const maze_image = alloc_resources.materials.textures.get("maze").?.image_alloc;

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
