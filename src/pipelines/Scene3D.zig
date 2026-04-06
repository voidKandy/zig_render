const std = @import("std");
const engine = @import("../root.zig");
const mesh_mod = engine.mesh;
const c = engine.clibs;
const Pipeline = @import("Pipeline.zig");
const PipelineBuilder = @import("PipelineBuilder.zig");
const ResourceManager = engine.ResourceManager;
const vki = engine.vulkan_init;
const vk = c.vk;
const vma = c.vma;
const checkVk = vki.checkVk;
const Allocator = std.mem.Allocator;
const Vec2 = engine.math.Vec2;
const Vec3 = engine.math.Vec3;

mesh_ids: []ResourceManager.ResourceID = undefined,
pipeline: vk.Pipeline = undefined,
layout: vk.PipelineLayout = undefined,
const Self = @This();

pub fn init(
    self: *Self,
    allocs: *engine.VulkanEngine.Allocators,
    init_data: Pipeline.InitData,
    resources: []const ResourceManager.ResourceID,
    device: vki.LogicalDevice,
    alloc_cbs: ?*vk.AllocationCallbacks,
) anyerror!void {
    var mesh_ids = std.ArrayList(ResourceManager.ResourceID).initCapacity(allocs.std, resources.len) catch @panic("OOM");
    for (0..resources.len) |i| {
        switch (resources[i]) {
            // just grabbing every mesh
            .mesh => mesh_ids.appendAssumeCapacity(resources[i]),
            else => {},
        }
    }
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

pub fn draw(self: Self, draw_data: Pipeline.DrawData, cmd: vk.CommandBuffer) void {
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
        const mesh_resource = draw_data.resources.query(id).?.mesh;
        vk.CmdBindVertexBuffers(cmd, 0, 1, &mesh_resource.mesh.vertex_buffer.buffer, &offset);
        vk.CmdBindIndexBuffer(cmd, mesh_resource.mesh.index_buffer.buffer, 0, vk.INDEX_TYPE_UINT16);
        vk.CmdDrawIndexed(cmd, @as(u32, @intCast(mesh_resource.mesh.indices.len)), 1, 0, 0, 0);
        // vk.CmdDraw(cmd, @as(u32, @intCast(mesh_resource.mesh.vertices.len)), 1, 0, 0);
    }
}

pub fn deinit(self: *Self, a: *engine.VulkanEngine.Allocators, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
    a.std.free(self.mesh_ids);
    vk.DestroyPipeline(device, self.pipeline, alloc_cbs);
    vk.DestroyPipelineLayout(device, self.layout, alloc_cbs);
}

fn createPipeline(
    a: Allocator,
    layout: vk.PipelineLayout,
    extent: vk.Extent2D,
    device: vk.Device,
    render_pass: vk.RenderPass,
    alloc_cbs: ?*vk.AllocationCallbacks,
) vk.Pipeline {
    var builder = PipelineBuilder.init(a, alloc_cbs);
    defer builder.deinit();
    const vert_shader = engine.shaders.createShaderModule(
        "uniform_buffer.vert",
        device,
        alloc_cbs,
    ) orelse @panic("failed to create vert shader module");
    defer vk.DestroyShaderModule(device, vert_shader, alloc_cbs);

    const frag_shader = engine.shaders.createShaderModule(
        "triangle.frag",
        device,
        alloc_cbs,
    ) orelse @panic("failed to create frag shader module");
    defer vk.DestroyShaderModule(device, frag_shader, alloc_cbs);

    builder.layout = layout;
    builder.shader_stages.clearRetainingCapacity();
    builder.shader_stages.append(builder.allocator, vki.pipelineShaderStageCreateInfo(vk.SHADER_STAGE_VERTEX_BIT, vert_shader, "main")) catch @panic("out of memory");
    builder.shader_stages.append(builder.allocator, vki.pipelineShaderStageCreateInfo(vk.SHADER_STAGE_FRAGMENT_BIT, frag_shader, "main")) catch @panic("out of memory");

    builder.setInputTopology(vk.PRIMITIVE_TOPOLOGY_TRIANGLE_LIST);

    const vertex_description = mesh_mod.Vertex3D.vertex_input_description;
    builder.vertex_input_info.pVertexAttributeDescriptions = vertex_description.attributes.ptr;
    builder.vertex_input_info.vertexAttributeDescriptionCount = vertex_description.attributes.len;

    builder.vertex_input_info.pVertexBindingDescriptions = vertex_description.bindings.ptr;
    builder.vertex_input_info.vertexBindingDescriptionCount = vertex_description.bindings.len;

    builder.viewport = .{
        .x = 0.0,
        .y = 0.0,
        .width = @as(f32, @floatFromInt(extent.width)),
        .height = @as(f32, @floatFromInt(extent.height)),
        .minDepth = 0.0,
        .maxDepth = 1.0,
    };

    builder.scissor = .{
        .offset = .{ .x = 0, .y = 0 },
        .extent = extent,
    };

    builder.setPolygonMode(vk.POLYGON_MODE_FILL);
    builder.setCullMode(vk.CULL_MODE_NONE, vk.FRONT_FACE_CLOCKWISE);
    builder.setMultisamplingNone();
    builder.color_blend_attachment = vki.defaultColorBlendAttachmentState();
    builder.disableBlending();

    // builder.setColorAttachmentFormat(self.draw_image.format);
    return builder.build(device, render_pass);
}
