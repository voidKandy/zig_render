const std = @import("std");
const core = @import("core");
const mesh_mod = core.mesh;
const c = core.clibs;
const PipelineObject = core.PipelineObject;
const PipelineBuilder = core.PipelineBuilder;
const ResourceManager = core.ResourceManager;
const vki = core.vulkan_init;
const vk = c.vk;
const vma = c.vma;
const checkVk = vki.checkVk;
const Allocator = std.mem.Allocator;
const Vec2 = core.math.Vec2;
const Vec3 = core.math.Vec3;

mesh_id: ResourceManager.ResourceID = undefined,
render_pass_id: ResourceManager.ResourceID = undefined,
pipeline: vk.Pipeline = undefined,
layout: vk.PipelineLayout = undefined,

const Self = @This();

pub fn init(
    self: *@This(),
    allocs: PipelineObject.Allocators,
    init_data: PipelineObject.InitData,
    resources: []const ResourceManager.ResourceID,
    device: vki.LogicalDevice,
    alloc_cbs: ?*vk.AllocationCallbacks,
) anyerror!void {
    if (resources.len != 1) return error.UnexpectedResourcesLength;
    if (resources[0] != .mesh3D) return error.UnexpectedResourceType;
    self.mesh_id = resources[0];

    {
        const ci = vki.pipelineLayoutCreateInfo();
        checkVk(vk.CreatePipelineLayout(device.handle, &ci, alloc_cbs, &self.layout)) catch
            @panic("failed to create triangle pipeline layout");
    }

    self.pipeline = createPipeline(allocs.std, self.layout, init_data.swapchain_extent, device.handle, init_data.main_render_pass, alloc_cbs);
}

pub fn draw(self: Self, draw_data: PipelineObject.DrawData, cmd: vk.CommandBuffer) void {
    vk.CmdBindPipeline(cmd, vk.PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);
    const mesh_resource = draw_data.resources.query(self.mesh_id) orelse @panic("NO MESH?");

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

    const offset: u64 = 0;
    vk.CmdBindVertexBuffers(cmd, 0, 1, &mesh_resource.mesh3D.vertex_buffer.buffer, &offset);
    vk.CmdSetScissor(cmd, 0, 1, &scissor);
    vk.CmdDraw(cmd, @as(u32, @intCast(mesh_resource.mesh3D.vertices.len)), 1, 0, 0);
}

pub fn deinit(self: *Self, _: PipelineObject.Allocators, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
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
    const vert_shader = core.shaders.createShaderModule(
        "colored_triangle.vert",
        device,
        alloc_cbs,
    ) orelse @panic("failed to create vert shader module");
    defer vk.DestroyShaderModule(device, vert_shader, alloc_cbs);

    const frag_shader = core.shaders.createShaderModule(
        "colored_triangle.frag",
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
    // builder.setDepthFormat(vk.FORMAT_UNDEFINED);

    return builder.build(device, render_pass);
}
