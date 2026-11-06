const std = @import("std");
const core = @import("../../root.zig");
const log = std.log.scoped(.RenderingManager);
const vk = core.clibs.vk;
const util = core.bindings.vulkan_util;
const vki = core.bindings.vulkan_init;
const checkVk = vki.checkVk;
const Meshes3DResource = core.resources.Meshes3D;
const Allocator = std.mem.Allocator;
const attachments =
    @import("./attachments.zig");

pub const Attachments = attachments.CreateManager(&[_]attachments.ManagerInfo{
    .{
        "depth",
        .{
            .usage = vk.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | vk.IMAGE_USAGE_SAMPLED_BIT,
            .description = .{
                // depth format is calculated later so we don't pass it here
                .samples = vk.SAMPLE_COUNT_1_BIT,
                .loadOp = vk.ATTACHMENT_LOAD_OP_CLEAR,
                .storeOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
                .stencilLoadOp = vk.ATTACHMENT_LOAD_OP_DONT_CARE,
                .stencilStoreOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
                .initialLayout = vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
                .finalLayout = vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
            },
        },
    },
    .{
        "position",
        .{
            .usage = vk.IMAGE_USAGE_COLOR_ATTACHMENT_BIT | vk.IMAGE_USAGE_SAMPLED_BIT,
            .description = .{
                .format = vk.FORMAT_R16G16B16A16_SFLOAT,
                .samples = vk.SAMPLE_COUNT_1_BIT,
                .loadOp = vk.ATTACHMENT_LOAD_OP_CLEAR,
                .storeOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
                .stencilLoadOp = vk.ATTACHMENT_LOAD_OP_DONT_CARE,
                .stencilStoreOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
                .initialLayout = vk.IMAGE_LAYOUT_UNDEFINED,
                .finalLayout = vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            },
        },
    },
    .{
        "normal",
        .{
            .usage = vk.IMAGE_USAGE_COLOR_ATTACHMENT_BIT | vk.IMAGE_USAGE_SAMPLED_BIT,
            .description = .{
                .format = vk.FORMAT_R16G16B16A16_SFLOAT,
                .samples = vk.SAMPLE_COUNT_1_BIT,
                .loadOp = vk.ATTACHMENT_LOAD_OP_CLEAR,
                .storeOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
                .stencilLoadOp = vk.ATTACHMENT_LOAD_OP_DONT_CARE,
                .stencilStoreOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
                .initialLayout = vk.IMAGE_LAYOUT_UNDEFINED,
                .finalLayout = vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            },
        },
    },
    .{
        "albedo",
        .{
            .usage = vk.IMAGE_USAGE_COLOR_ATTACHMENT_BIT | vk.IMAGE_USAGE_SAMPLED_BIT,
            .description = .{
                .format = vk.FORMAT_R8G8B8A8_UNORM,
                .samples = vk.SAMPLE_COUNT_1_BIT,
                .loadOp = vk.ATTACHMENT_LOAD_OP_CLEAR,
                .storeOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
                .stencilLoadOp = vk.ATTACHMENT_LOAD_OP_DONT_CARE,
                .stencilStoreOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
                .initialLayout = vk.IMAGE_LAYOUT_UNDEFINED,
                .finalLayout = vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            },
        },
    },
    .{
        "ssao",
        .{
            .usage = vk.IMAGE_USAGE_COLOR_ATTACHMENT_BIT | vk.IMAGE_USAGE_SAMPLED_BIT,
            .description = .{
                .format = vk.FORMAT_R8G8B8A8_UNORM,
                .samples = vk.SAMPLE_COUNT_1_BIT,
                .loadOp = vk.ATTACHMENT_LOAD_OP_CLEAR,
                .storeOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
                .stencilLoadOp = vk.ATTACHMENT_LOAD_OP_DONT_CARE,
                .stencilStoreOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
                .initialLayout = vk.IMAGE_LAYOUT_UNDEFINED,
                .finalLayout = vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            },
        },
    },
});

pub const Swapchain = @import("./Swapchain.zig");
pub const Geometry = @import("./Geometry.zig");
pub const Meshes2D = @import("./Meshes2D.zig");
pub const PhysicsDebug = @import("./PhysicsDebug.zig");

geometry: ?Geometry = null,
meshes2D: ?Meshes2D = null,
physics_debug: ?PhysicsDebug = null,

main_render_pass: vk.RenderPass = undefined,

pub const MAIN_RENDER_PASS_IMAGE_FORMAT = vk.FORMAT_R16G16B16A16_SFLOAT;

pub const CreateInfo = struct {
    physics_debug: ?*const core.engine.Physics.DebugContext,
    meshes3D: bool,
    meshes2D: bool,
};

pub fn init(
    ci: CreateInfo,
) Allocator.Error!@This() {
    const meshes3D =
        if (ci.meshes3D) Geometry{} else null;
    const meshes2D =
        if (ci.meshes2D) Meshes2D{} else null;
    const physics_debug =
        if (ci.physics_debug) |db| PhysicsDebug{ .debug_ctx_ptr = db } else null;

    if (meshes2D == null and meshes3D == null)
        @panic("attempted to create empty renderer??");

    return .{
        .meshes2D = meshes2D,
        .geometry = meshes3D,
        .physics_debug = physics_debug,
    };
}

pub fn deinit(
    self: *@This(),
    allocs: core.engine.Allocators,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    if (self.meshes2D) |*m| m.deinit(allocs, device, alloc_cbs);
    if (self.geometry) |*m| m.deinit(allocs, device, alloc_cbs);
    if (self.physics_debug) |*p| p.deinit(allocs, device, alloc_cbs);
    vk.DestroyRenderPass(device, self.main_render_pass, alloc_cbs);
}

pub fn updateSets(
    self: @This(),
    swapchain: *const core.engine.Renderer.Swapchain,
    device: vk.Device,
    allocated_resources: *core.resources.Manager.AllocatedData,
) void {
    if (self.meshes2D != null) Meshes2D.updateSets(device, allocated_resources);
    if (self.geometry != null) {
        Geometry.updateBufferSets(device, allocated_resources);
        Geometry.updateAttachmentSets(device, swapchain, allocated_resources);
    }

    if (self.physics_debug != null) PhysicsDebug.updateSets(device, allocated_resources);
}

pub fn registerSetsAndBuffers(
    self: @This(),
    a: Allocator,
    device: vk.Device,
    resources: *core.resources.Manager,
    alloc_cbs: ?*vk.AllocationCallbacks,
) Allocator.Error!void {
    if (self.meshes2D != null) try Meshes2D.registerSetsAndBuffers(a, device, resources, alloc_cbs);
    if (self.geometry != null) try Geometry.registerSetsAndBuffers(a, device, resources, alloc_cbs);
    if (self.physics_debug != null) try PhysicsDebug.registerSetsAndBuffers(a, device, resources, alloc_cbs);
}

pub fn getInstances(self: *@This(), a: Allocator, world: *core.engine.world.GameWorld) Allocator.Error!void {
    if (self.meshes2D) |*m| try m.getInstances(a, world);
    if (self.geometry) |*m| try m.getInstances(a, world);
}

pub fn syncResources(self: @This(), alloc_resources: *const core.resources.Manager.AllocatedData) void {
    if (self.meshes2D) |m| m.syncResources(alloc_resources);
    if (self.geometry) |m| m.syncResources(alloc_resources);
    if (self.physics_debug) |p| p.syncResources(alloc_resources);
}

pub fn initPipelines(
    self: *@This(),
    common: core.engine.pipelines.Common,
    resources: *const core.resources.Manager,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    if (self.meshes2D) |*m| m.initPipeline(common, resources, alloc_cbs);
    if (self.geometry) |*m| m.initPipeline(common, resources, alloc_cbs);
    if (self.physics_debug) |*p| p.initPipeline(common, resources, alloc_cbs);
}

pub fn recordCommands(
    self: @This(),
    swapchain: *const Swapchain,
    resources: *const core.resources.Manager,
    allocated_resources: *const core.resources.Manager.AllocatedData,
    cmd: vk.CommandBuffer,
) void {
    if (self.geometry) |m| m.recordCommands(resources, allocated_resources, cmd);
    if (self.physics_debug) |p| p.recordCommands(allocated_resources, cmd);
    if (self.meshes2D) |m| m.recordCommands(swapchain, resources, allocated_resources, cmd);
}

pub fn drawImgui(self: *@This(), ctx: core.engine.systems.manager.DrawImguiContext) void {
    if (self.meshes2D) |*m| m.drawImgui(ctx);
    if (self.geometry) |*m| m.drawImgui(ctx);
    if (self.physics_debug) |*p| p.drawImgui(ctx);
}

pub fn createMainRenderPass(
    self: *@This(),
    log_device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const final_attachment_description = vk.AttachmentDescription{
        .format = core.engine.Renderer.MAIN_RENDER_PASS_IMAGE_FORMAT,
        .samples = vk.SAMPLE_COUNT_1_BIT,
        .loadOp = vk.ATTACHMENT_LOAD_OP_LOAD,
        .storeOp = vk.ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = vk.ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .finalLayout = vk.IMAGE_LAYOUT_PRESENT_SRC_KHR,
    };

    const attachment_descriptions = Attachments.attachmentDescriptions();

    var all_descriptions: [@typeInfo(Attachments.Tags).@"enum".field_names.len + 1]vk.AttachmentDescription = undefined;
    all_descriptions[0] = final_attachment_description;
    @memcpy(all_descriptions[1..], &attachment_descriptions.values);

    const gbuffer_attachments = Geometry.GraphicsPipelines.GBufferDescription.getAttachmentReferences();
    const ssao_attachments = Geometry.GraphicsPipelines.SSAODescription.getAttachmentReferences();
    const final_attachments = Geometry.GraphicsPipelines.FinalDescription.getAttachmentReferences();

    const gbuffer_subpass =
        vk.SubpassDescription{
            .pipelineBindPoint = vk.PIPELINE_BIND_POINT_GRAPHICS,
            .colorAttachmentCount = @intCast(gbuffer_attachments.color.len),
            .pColorAttachments = &gbuffer_attachments.color,
            .inputAttachmentCount = @intCast(gbuffer_attachments.input.len),
            .pInputAttachments = &gbuffer_attachments.input,
            .pDepthStencilAttachment = if (gbuffer_attachments.depth) |a| &a else null,
        };

    const ssao_subpass =
        vk.SubpassDescription{
            .pipelineBindPoint = vk.PIPELINE_BIND_POINT_GRAPHICS,
            .colorAttachmentCount = @intCast(ssao_attachments.color.len),
            .pColorAttachments = &ssao_attachments.color,
            .inputAttachmentCount = @intCast(ssao_attachments.input.len),
            .pInputAttachments = &ssao_attachments.input,
            .pDepthStencilAttachment = if (ssao_attachments.depth) |a| &a else null,
        };

    const final_subpass =
        vk.SubpassDescription{
            .pipelineBindPoint = vk.PIPELINE_BIND_POINT_GRAPHICS,
            .colorAttachmentCount = 1,
            .pColorAttachments = &.{
                .attachment = 0,
                .layout = vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            },
            .inputAttachmentCount = @intCast(final_attachments.input.len),
            .pInputAttachments = &final_attachments.input,
            .pDepthStencilAttachment = if (final_attachments.depth) |a| &a else null,
        };

    const subpass_descriptions = [_]vk.SubpassDescription{
        gbuffer_subpass,
        ssao_subpass,
        final_subpass,
    };

    const gbuffer_stages = vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | vk.PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT;
    const gbuffer_access = vk.ACCESS_COLOR_ATTACHMENT_WRITE_BIT | vk.ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;

    const dependencies = [_]vk.SubpassDependency{
        .{
            .srcSubpass = vk.SUBPASS_EXTERNAL,
            .dstSubpass = 2,
            .srcStageMask = gbuffer_stages,
            .srcAccessMask = gbuffer_access,
            .dstStageMask = vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstAccessMask = vk.ACCESS_COLOR_ATTACHMENT_READ_BIT | vk.ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        },
        .{
            .srcSubpass = 0,
            .dstSubpass = 1,
            .srcStageMask = gbuffer_stages,
            .srcAccessMask = gbuffer_access,
            .dstStageMask = vk.PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            .dstAccessMask = vk.ACCESS_INPUT_ATTACHMENT_READ_BIT,
            .dependencyFlags = vk.DEPENDENCY_BY_REGION_BIT,
        },
        .{
            .srcSubpass = 1,
            .dstSubpass = 2,
            .srcStageMask = vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = vk.ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dstStageMask = vk.PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            .dstAccessMask = vk.ACCESS_INPUT_ATTACHMENT_READ_BIT,
            .dependencyFlags = vk.DEPENDENCY_BY_REGION_BIT,
        },
        .{
            .srcSubpass = 0,
            .dstSubpass = 2,
            .srcStageMask = gbuffer_stages,
            .srcAccessMask = gbuffer_access,
            .dstStageMask = vk.PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
            .dstAccessMask = vk.ACCESS_INPUT_ATTACHMENT_READ_BIT,
            .dependencyFlags = vk.DEPENDENCY_BY_REGION_BIT,
        },
    };

    const ci = vk.RenderPassCreateInfo{
        .sType = vk.STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = all_descriptions.len,
        .pAttachments = &all_descriptions,
        .subpassCount = subpass_descriptions.len,
        .pSubpasses = &subpass_descriptions,
        .dependencyCount = dependencies.len,
        .pDependencies = &dependencies,
    };

    checkVk(vk.CreateRenderPass(log_device, &ci, alloc_cbs, &self.main_render_pass)) catch @panic("failed to create render pass");
}
