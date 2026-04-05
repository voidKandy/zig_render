const std = @import("std");
const core = @import("core");
const log = std.log.scoped(.TexturedMesh);
const mesh_mod = core.mesh;
const c = core.clibs;
const Ecs = core.VulkanEngine.ResourceEcs;
const PipelineObject = core.PipelineObject;
const PipelineBuilder = core.PipelineBuilder;
const ResourceManager = core.ResourceManager;
const vki = core.vulkan_init;
const vk = c.vk;
const vma = c.vma;
const checkVk = vki.checkVk;

const Self = @This();

_entities: []u32,
pipeline: vk.Pipeline = undefined,
layout: vk.PipelineLayout = undefined,

// const WriteData = struct {
//     image: ?core.vma_usage.AllocatedImage = null,
//     sampler: ?vk.Sampler = null,
//     mesh: core.mesh.Mesh3D,
// };

pub fn getWriteData(self: @This(), ecs: Ecs) void {
    //     // const entity = ecs.queryEntities(.{ .id = self._entity });
    const res = ecs.queryEntities(.{ .query = .{ .is = .{ .sig = Ecs.componentsSignature(&[_]Ecs.ComponentTag{
        .mesh3D,
    }), .rule = .at_least } } }) catch @panic("query failed");
    const q = res.?.query;
}

pub fn initOnEntity(
    self: *Self,
    allocs: *core.VulkanEngine.Allocators,
    engine_ecs: core.VulkanEngine.ResourceManager,
    init_data: PipelineObject.InitData,
    resources: []const ResourceManager.ResourceID,
    device: vki.LogicalDevice,
    alloc_cbs: ?*vk.AllocationCallbacks,
) anyerror!void {
    const entity = engine_ecs.queryEntities(.{ .id = self._entity });

    // var mesh_ids = std.ArrayList(u32).initCapacity(allocs.std, resources.len) catch @panic("OOM");
    // for (0..resources.len) |i| {
    //     switch (resources[i]) {
    //         .image => self.image_id = resources[i],
    //         .sampler => self.sampler_id = resources[i],
    //         .mesh3D => mesh_ids.appendAssumeCapacity(resources[i]),
    //         else => @panic("UNEXPECTED RESOURCE TYPE"),
    //     }
    // }
    self.mesh_ids = mesh_ids.toOwnedSlice(allocs.std) catch @panic("OOM");

    {
        const ci = vk.PipelineLayoutCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .setLayoutCount = 1,
            // need a way to pass descriptor set
            // BAD
            // this key is set in the function that creates bound descriptors. this is a logic leak
            .pSetLayouts = &init_data.descriptor_set_layout,
            // .pushConstantRangeCount = 1,
            // .pPushConstantRanges = &push_constant,
        };
        checkVk(vk.CreatePipelineLayout(device.handle, &ci, alloc_cbs, &self.layout)) catch
            @panic("failed to create triangle pipeline layout");
    }

    self.pipeline = createPipeline(allocs.std, self.layout, init_data.swapchain_extent, device.handle, init_data.main_render_pass, alloc_cbs);
}

pub fn writeToCommandBuffer(self: Self, cmd: vk.CommandBuffer, draw_data: PipelineObject.DrawData) void {
    vk.CmdBindPipeline(cmd, vk.PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);

    const viewport = vk.Viewport{
        .x = 0,
        .y = 0,
        .width = @as(f32, (@floatFromInt(draw_data.swapchain.extent.width))),
        .height = @as(f32, (@floatFromInt(draw_data.swapchain.extent.height))),
        .minDepth = 0.0,
        .maxDepth = 1.0,
    };
    vk.CmdSetViewport(cmd, 0, 1, &viewport);

    const scissor = vk.Rect2D{
        .offset = .{
            .x = 0,
            .y = 0,
        },
        .extent = .{
            .width = draw_data.swapchain.extent.width,
            .height = draw_data.swapchain.extent.height,
        },
    };

    vk.CmdSetScissor(cmd, 0, 1, &scissor);

    vk.CmdBindDescriptorSets(
        cmd,
        vk.PIPELINE_BIND_POINT_GRAPHICS,
        self.layout,
        0,
        1,
        &draw_data.descriptor_set,
        0,
        null,
    );

    const offset: u64 = 0;
    for (self.mesh_ids) |id| {
        const mesh_resource = draw_data.resources.query(id) orelse @panic("NO MESH?");
        vk.CmdBindVertexBuffers(cmd, 0, 1, &mesh_resource.mesh3D.vertex_buffer.buffer, &offset);
        vk.CmdDraw(cmd, @as(u32, @intCast(mesh_resource.mesh3D.vertices.len)), 1, 0, 0);
    }
}
