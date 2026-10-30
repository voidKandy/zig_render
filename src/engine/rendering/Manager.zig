const std = @import("std");
const core = @import("../../root.zig");
const log = std.log.scoped(.RenderingManager);
const vk = core.clibs.vk;
const util = core.bindings.vulkan_util;
const vki = core.bindings.vulkan_init;
const checkVk = vki.checkVk;
const Meshes3DResource = core.resources.Meshes3D;
const Allocator = std.mem.Allocator;

pub const Swapchain = @import("./Swapchain.zig");
pub const Meshes3D = @import("./Meshes3DNew.zig");
pub const Meshes2D = @import("./Meshes2D.zig");
pub const PhysicsDebug = @import("./PhysicsDebug.zig");

meshes3D: ?Meshes3D = null,
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
        if (ci.meshes3D) Meshes3D{} else null;
    const meshes2D =
        if (ci.meshes2D) Meshes2D{} else null;
    const physics_debug =
        if (ci.physics_debug) |db| PhysicsDebug{ .debug_ctx_ptr = db } else null;

    if (meshes2D == null and meshes3D == null)
        @panic("attempted to create empty renderer??");

    return .{
        .meshes2D = meshes2D,
        .meshes3D = meshes3D,
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
    if (self.meshes3D) |*m| m.deinit(allocs, device, alloc_cbs);
    if (self.physics_debug) |*p| p.deinit(allocs, device, alloc_cbs);
    vk.DestroyRenderPass(device, self.main_render_pass, alloc_cbs);
}

pub fn updateSets(
    self: @This(),
    device: vk.Device,
    allocated_resources: *core.resources.Manager.AllocatedData,
) void {
    if (self.meshes2D != null) Meshes2D.updateSets(device, allocated_resources);
    if (self.meshes3D != null) Meshes3D.updateSets(device, allocated_resources);
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
    if (self.meshes3D != null) try Meshes3D.registerSetsAndBuffers(a, device, resources, alloc_cbs);
    if (self.physics_debug != null) try PhysicsDebug.registerSetsAndBuffers(a, device, resources, alloc_cbs);
}

pub fn getInstances(self: *@This(), a: Allocator, world: *core.engine.world.GameWorld) Allocator.Error!void {
    if (self.meshes2D) |*m| try m.getInstances(a, world);
    if (self.meshes3D) |*m| try m.getInstances(a, world);
}

pub fn syncResources(self: @This(), alloc_resources: *const core.resources.Manager.AllocatedData) void {
    if (self.meshes2D) |m| m.syncResources(alloc_resources);
    if (self.meshes3D) |m| m.syncResources(alloc_resources);
    if (self.physics_debug) |p| p.syncResources(alloc_resources);
}

pub fn initPipelines(
    self: *@This(),
    common: core.engine.pipelines.Common,
    resources: *const core.resources.Manager,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    if (self.meshes2D) |*m| m.initPipeline(common, resources, alloc_cbs);
    if (self.meshes3D) |*m| m.initPipeline(common, resources, alloc_cbs);
    if (self.physics_debug) |*p| p.initPipeline(common, resources, alloc_cbs);
}

pub fn recordCommands(
    self: @This(),
    swapchain: *const Swapchain,
    resources: *const core.resources.Manager,
    allocated_resources: *const core.resources.Manager.AllocatedData,
    cmd: vk.CommandBuffer,
) void {
    if (self.meshes3D) |m| m.recordCommands(resources, allocated_resources, cmd);
    if (self.physics_debug) |p| p.recordCommands(allocated_resources, cmd);
    if (self.meshes2D) |m| m.recordCommands(swapchain, resources, allocated_resources, cmd);
}

pub fn drawImgui(self: *@This(), ctx: core.engine.systems.manager.DrawImguiContext) void {
    if (self.meshes2D) |*m| m.drawImgui(ctx);
    if (self.meshes3D) |*m| m.drawImgui(ctx);
    if (self.physics_debug) |*p| p.drawImgui(ctx);
}

pub fn createMainRenderPass(
    self: *@This(),
    swapchain: *const Swapchain,
    log_device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    const attachment_descriptions = swapchain.attachments.attachmentDescriptions();

    const gbuffer_color_attachments = [_]vk.AttachmentReference{
        .{
            .attachment = @backingInt(Swapchain.Attachments.Tags.normal),
            .layout = vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        },
        .{
            .attachment = @backingInt(Swapchain.Attachments.Tags.position),
            .layout = vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        },
        .{
            .attachment = @backingInt(Swapchain.Attachments.Tags.albedo),
            .layout = vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        },
    };

    const gbuffer_subpass =
        vk.SubpassDescription{
            .pipelineBindPoint = vk.PIPELINE_BIND_POINT_GRAPHICS,
            .colorAttachmentCount = gbuffer_color_attachments.len,
            .pColorAttachments = &gbuffer_color_attachments,
            .pDepthStencilAttachment = &.{
                .attachment = @backingInt(Swapchain.Attachments.Tags.depth),
                .layout = vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
            },
        };

    const final_input_attachments = [_]vk.AttachmentReference{
        .{
            .attachment = @backingInt(Swapchain.Attachments.Tags.depth),
            .layout = vk.IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL,
        },
        .{
            .attachment = @backingInt(Swapchain.Attachments.Tags.normal),
            .layout = vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        },
        .{
            .attachment = @backingInt(Swapchain.Attachments.Tags.position),
            .layout = vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        },
        .{
            .attachment = @backingInt(Swapchain.Attachments.Tags.albedo),
            .layout = vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        },
    };
    const final_subpass =
        vk.SubpassDescription{
            .pipelineBindPoint = vk.PIPELINE_BIND_POINT_GRAPHICS,
            .colorAttachmentCount = 1,
            .pColorAttachments = &.{
                .attachment = @backingInt(Swapchain.Attachments.Tags.final),
                .layout = vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
            },
            .inputAttachmentCount = final_input_attachments.len,
            .pInputAttachments = &final_input_attachments,
        };

    const subpass_descriptions = [_]vk.SubpassDescription{
        gbuffer_subpass,
        final_subpass,
    };

    const dependency = vk.SubpassDependency{
        .srcSubpass = vk.SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | vk.PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
        .srcAccessMask = vk.ACCESS_COLOR_ATTACHMENT_WRITE_BIT |
            vk.ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
        .dstStageMask = vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | vk.PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
        .dstAccessMask = vk.ACCESS_COLOR_ATTACHMENT_WRITE_BIT |
            vk.ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
    };

    const ci = vk.RenderPassCreateInfo{
        .sType = vk.STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = attachment_descriptions.values.len,
        .pAttachments = &attachment_descriptions.values,
        .subpassCount = subpass_descriptions.len,
        .pSubpasses = &subpass_descriptions,
        .dependencyCount = 1,
        .pDependencies = &dependency,
    };

    checkVk(vk.CreateRenderPass(log_device, &ci, alloc_cbs, &self.main_render_pass)) catch @panic("failed to create render pass");
}
