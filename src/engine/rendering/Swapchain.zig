const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../../root.zig");
const log = std.log.scoped(.Swapchain);
const vma_usage = core.bindings.vma_usage;
const vki = core.bindings.vulkan_init;
const vku = core.bindings.vulkan_util;
const vk = core.clibs.vk;
const checkVk = vki.checkVk;
const vma = core.clibs.vma;
const sdl = core.clibs.sdl;

handle: vk.SwapchainKHR = null,
images: []vk.Image = &.{},
/// one finish semaphore per swapchain image
render_semaphores: []vk.Semaphore = &.{},
image_views: []vk.ImageView = &.{},
framebuffers: []vk.Framebuffer = &.{},
format: vk.Format = undefined,
extent: vk.Extent2D = undefined,
attachments: Attachments,
// depth_resource: ?vma_usage.AllocatedImage = null,

const Swapchain = @This();

const FrameBufferAttachment = struct {
    image: vma_usage.AllocatedImage,
    format: vk.Format,
};

pub const Attachments = struct {
    const Tags = enum {
        final,
        depth,
        // position,
        // normal,
        // albedo,

        fn layout(self: *const @This()) vk.ImageLayout {
            return switch (self.*) {
                .final => vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                .depth => vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
                // .position => vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                // .normal => vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                // .albedo => vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            };
        }
    };

    /// Holds all attachments other than 'final'
    /// 'final' is handled by `Swapchain`
    const Plexe =
        @Struct(
            .auto,
            null,
            std.meta.fieldNames(Tags)[1..],
            &@splat(FrameBufferAttachment),
            &@splat(.{}),
        );

    plexe: Plexe,

    pub fn deinit(
        self: *@This(),
        vma_a: vma.Allocator,
        device: vk.Device,
        alloc_cbs: ?*vk.AllocationCallbacks,
    ) void {
        self.plexe.depth.image.deinit(vma_a, device, alloc_cbs);
        // self.plexe.position.image.deinit(vma_a, device, alloc_cbs);
        // self.plexe.normal.image.deinit(vma_a, device, alloc_cbs);
        // self.plexe.albedo.image.deinit(vma_a, device, alloc_cbs);
    }

    /// final image is passed from swapchain
    fn imageViews(self: *const @This(), final_image: vk.ImageView) [std.meta.fields(Tags).len]vk.ImageView {
        var views: [std.meta.fields(Tags).len]vk.ImageView = undefined;
        inline for (&views, std.meta.fields(Tags)) |*v, enfld| {
            const tag = comptime std.meta.stringToEnum(Tags, enfld.name).?;
            if (tag == .final)
                v.* = final_image
            else
                v.* = @field(self.plexe, enfld.name).image.view;
        }
        return views;
    }

    pub fn attachmentReferences() std.EnumArray(Tags, vk.AttachmentReference) {
        var refs = std.EnumArray(Tags, vk.AttachmentReference).initUndefined();
        inline for (std.meta.fields(Tags)) |enfld| {
            const tag = comptime std.meta.stringToEnum(Tags, enfld.name).?;
            refs.set(tag, vk.AttachmentReference{
                .attachment = @intFromEnum(tag),
                .layout = tag.layout(),
            });
        }
        return refs;
    }

    pub fn attachmentDescriptions(self: *const @This()) std.EnumArray(Tags, vk.AttachmentDescription) {
        var descs = std.EnumArray(Tags, vk.AttachmentDescription).initUndefined();
        inline for (std.meta.fields(Tags)) |enfld| {
            const tag = comptime std.meta.stringToEnum(Tags, enfld.name).?;
            const format = if (tag == .final)
                core.engine.Renderer.MAIN_RENDER_PASS_IMAGE_FORMAT
            else
                @field(self.plexe, enfld.name).format;

            const desc: vk.AttachmentDescription =
                switch (tag) {
                    .final => .{
                        .format = format,
                        .samples = vk.SAMPLE_COUNT_1_BIT,
                        .loadOp = vk.ATTACHMENT_LOAD_OP_LOAD,
                        .storeOp = vk.ATTACHMENT_STORE_OP_STORE,
                        .stencilLoadOp = vk.ATTACHMENT_LOAD_OP_DONT_CARE,
                        .stencilStoreOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
                        .initialLayout = vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                        .finalLayout = vk.IMAGE_LAYOUT_PRESENT_SRC_KHR,
                    },

                    .depth => .{
                        .format = format,
                        .samples = vk.SAMPLE_COUNT_1_BIT,
                        .loadOp = vk.ATTACHMENT_LOAD_OP_LOAD,
                        .storeOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
                        .stencilLoadOp = vk.ATTACHMENT_LOAD_OP_DONT_CARE,
                        .stencilStoreOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
                        .initialLayout = vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
                        .finalLayout = vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
                    },
                    // .position => .{
                    //     .format = format,
                    //     .samples = vk.SAMPLE_COUNT_1_BIT,
                    //     .loadOp = vk.ATTACHMENT_LOAD_OP_CLEAR,
                    //     .storeOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
                    //     .stencilLoadOp = vk.ATTACHMENT_LOAD_OP_DONT_CARE,
                    //     .stencilStoreOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
                    //     .initialLayout = vk.IMAGE_LAYOUT_UNDEFINED,
                    //     .finalLayout = vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                    // },
                    // .normal => .{
                    //     .format = format,
                    //     .samples = vk.SAMPLE_COUNT_1_BIT,
                    //     .loadOp = vk.ATTACHMENT_LOAD_OP_CLEAR,
                    //     .storeOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
                    //     .stencilLoadOp = vk.ATTACHMENT_LOAD_OP_DONT_CARE,
                    //     .stencilStoreOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
                    //     .initialLayout = vk.IMAGE_LAYOUT_UNDEFINED,
                    //     .finalLayout = vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                    // },
                    // .albedo => .{
                    //     .format = format,
                    //     .samples = vk.SAMPLE_COUNT_1_BIT,
                    //     .loadOp = vk.ATTACHMENT_LOAD_OP_CLEAR,
                    //     .storeOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
                    //     .stencilLoadOp = vk.ATTACHMENT_LOAD_OP_DONT_CARE,
                    //     .stencilStoreOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
                    //     .initialLayout = vk.IMAGE_LAYOUT_UNDEFINED,
                    //     .finalLayout = vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                    // },
                };

            descs.set(tag, desc);
        }

        return descs;
    }

    fn findDepthFormat(device: vki.PhysicalDevice) vk.Format {
        return device.findSupportedFormat(
            &[_]vk.Format{ vk.FORMAT_D32_SFLOAT, vk.FORMAT_D32_SFLOAT_S8_UINT, vk.FORMAT_D24_UNORM_S8_UINT },
            vk.IMAGE_TILING_OPTIMAL,
            vk.FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT,
        ) catch @panic("failed to find depth format");
    }

    /// Transitions depth image into DepthStencil format
    /// BAD
    /// (see call site)
    pub fn transitionDepth(
        cmd: vk.CommandBuffer,
        attachment: FrameBufferAttachment,
    ) void {
        vku.transitionImageLayout(
            cmd,
            attachment.image.image,
            vk.IMAGE_LAYOUT_UNDEFINED,
            vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
            0,
            vk.ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT |
                vk.ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
            vk.PIPELINE_STAGE_TOP_OF_PIPE_BIT,
            vk.PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
        );
    }

    fn createAttachment(
        vma_a: vma.Allocator,
        logical_device: vk.Device,
        swapchain_extent: vk.Extent2D,
        format: vk.Format,
        usage: vk.ImageUsageFlags,
        vk_alloc_cbs: ?*vk.AllocationCallbacks,
    ) FrameBufferAttachment {
        const extent = vk.Extent3D{
            .depth = 1,
            .height = swapchain_extent.height,
            .width = swapchain_extent.width,
        };
        var image: vma_usage.AllocatedImage = undefined;

        const ci = vk.ImageCreateInfo{
            .sType = vk.STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType = vk.IMAGE_TYPE_2D,
            .format = format,
            .extent = extent,
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = vk.SAMPLE_COUNT_1_BIT,
            .tiling = vk.IMAGE_TILING_OPTIMAL,
            .usage = usage | vk.IMAGE_USAGE_INPUT_ATTACHMENT_BIT,
            .sharingMode = vk.SHARING_MODE_EXCLUSIVE,
            .initialLayout = vk.IMAGE_LAYOUT_UNDEFINED,
        };

        const ai = vma.AllocationCreateInfo{
            .usage = vma.MEMORY_USAGE_GPU_ONLY,
            .requiredFlags = vk.MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        };

        checkVk(vma.CreateImage(
            vma_a,
            &ci,
            &ai,
            &image.image,
            &image.allocation,
            null,
        )) catch @panic("failed to create image");

        const aspect_mask: u32 =
            switch (usage) {
                vk.IMAGE_USAGE_COLOR_ATTACHMENT_BIT => vk.IMAGE_ASPECT_COLOR_BIT,
                vk.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT => vk.IMAGE_ASPECT_DEPTH_BIT,
                // | vk.IMAGE_ASPECT_STENCIL_BIT,
                else => @panic("UNEXPECTED USAGE FLAG"),
            };

        const imvi_ci = vk.ImageViewCreateInfo{
            .sType = vk.STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = image.image,
            .viewType = vk.IMAGE_VIEW_TYPE_2D,
            .format = format,
            .subresourceRange = .{
                .aspectMask = aspect_mask,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        checkVk(vk.CreateImageView(
            logical_device,
            &imvi_ci,
            vk_alloc_cbs,
            &image.view,
        )) catch @panic("Failed to create image view");

        return .{
            .image = image,
            .format = format,
        };
    }

    pub fn init(
        vma_a: vma.Allocator,
        physical_device: vki.PhysicalDevice,
        logical_device: vk.Device,
        swapchain_extent: vk.Extent2D,
        vk_alloc_cbs: ?*vk.AllocationCallbacks,
    ) @This() {
        const depth = createAttachment(
            vma_a,
            logical_device,
            swapchain_extent,
            findDepthFormat(physical_device),
            vk.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
            vk_alloc_cbs,
        );

        // const position = createAttachment(
        //     vma_a,
        //     logical_device,
        //     swapchain_extent,
        //     vk.FORMAT_R16G16B16A16_SFLOAT,
        //     vk.IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        //     vk_alloc_cbs,
        // );

        // const normal = createAttachment(
        //     vma_a,
        //     logical_device,
        //     swapchain_extent,
        //     vk.FORMAT_R16G16B16A16_SFLOAT,
        //     vk.IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        //     vk_alloc_cbs,
        // );

        // const color = createAttachment(
        //     vma_a,
        //     logical_device,
        //     swapchain_extent,
        //     vk.FORMAT_R8G8B8A8_UNORM,
        //     vk.IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        //     vk_alloc_cbs,
        // );

        return .{
            .plexe = .{
                .depth = depth,
                // .position = position,
                // .normal = normal,
                // .color = color,
            },
        };
    }
};

pub const CreateOpts = struct {
    physical_device: vki.PhysicalDevice,
    logical_device: vk.Device,
    surface: vk.SurfaceKHR,
    old_swapchain: vk.SwapchainKHR = null,
    vsync: bool = false,
    triple_buffer: bool = false,
    window_width: u32 = 0,
    window_height: u32 = 0,
    alloc_cb: ?*vk.AllocationCallbacks = null,
};

pub fn create(allocs: core.engine.Allocators, opts: CreateOpts) (vki.VkError || Allocator.Error)!@This() {
    const support_info = try SupportInfo.init(allocs.std, opts.physical_device.handle, opts.surface);
    defer support_info.deinit(allocs.std);

    const format = support_info.pickSwapchainFormat(opts);
    const present_mode = support_info.pickSwapchainPresentMode(opts);
    const extent = support_info.makeSwapchainExtent(opts);

    const image_count = blk: {
        const desired_count = support_info.capabilities.minImageCount + 1;
        if (support_info.capabilities.maxImageCount > 0) {
            break :blk @min(desired_count, support_info.capabilities.maxImageCount);
        }
        break :blk desired_count;
    };

    var swapchain_info = vk.SwapchainCreateInfoKHR{
        .sType = vk.STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = opts.surface,
        .minImageCount = image_count,
        .imageFormat = format,
        .imageColorSpace = vk.COLOR_SPACE_SRGB_NONLINEAR_KHR,
        .imageExtent = extent,
        .imageArrayLayers = 1,
        .imageUsage = vk.IMAGE_USAGE_COLOR_ATTACHMENT_BIT | vk.IMAGE_USAGE_TRANSFER_SRC_BIT | vk.IMAGE_USAGE_TRANSFER_DST_BIT,
        .preTransform = support_info.capabilities.currentTransform,
        .compositeAlpha = vk.COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = present_mode,
        .clipped = vk.TRUE,
        .oldSwapchain = opts.old_swapchain,
    };

    if (opts.physical_device.graphics_queue_family != opts.physical_device.present_queue_family) {
        swapchain_info.imageSharingMode = vk.SHARING_MODE_CONCURRENT;
        swapchain_info.queueFamilyIndexCount = 2;
        swapchain_info.pQueueFamilyIndices = &[_]u32{
            opts.physical_device.graphics_queue_family,
            opts.physical_device.present_queue_family,
        };
    } else {
        swapchain_info.imageSharingMode = vk.SHARING_MODE_EXCLUSIVE;
    }

    var swapchain: vk.SwapchainKHR = undefined;
    try checkVk(vk.CreateSwapchainKHR(opts.logical_device, &swapchain_info, opts.alloc_cb, &swapchain));
    errdefer vk.DestroySwapchainKHR(opts.logical_device, swapchain, opts.alloc_cb);
    log.info("Created vulkan swapchain\n", .{});

    // Try and fetch the images from the swpachain.
    var swapchain_image_count: u32 = undefined;
    try checkVk(vk.GetSwapchainImagesKHR(opts.logical_device, swapchain, &swapchain_image_count, null));
    const swapchain_images = try allocs.std.alloc(vk.Image, swapchain_image_count);
    errdefer allocs.std.free(swapchain_images);
    try checkVk(vk.GetSwapchainImagesKHR(opts.logical_device, swapchain, &swapchain_image_count, swapchain_images.ptr));

    // Create image views for the swapchain images.
    const swapchain_image_views = try allocs.std.alloc(vk.ImageView, swapchain_image_count);
    errdefer allocs.std.free(swapchain_image_views);

    for (swapchain_images, swapchain_image_views) |image, *view| {
        view.* = try createImageView(opts.logical_device, image, format, vk.IMAGE_ASPECT_COLOR_BIT, opts.alloc_cb);
    }

    const semaphore_ci = vk.SemaphoreCreateInfo{
        .sType = vk.STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
    };
    const semaphores = allocs.std.alloc(vk.Semaphore, swapchain_image_count) catch @panic("Out of memory");
    errdefer allocs.std.free(semaphores);

    for (0..semaphores.len) |i| {
        checkVk(vk.CreateSemaphore(opts.logical_device, &semaphore_ci, opts.alloc_cb, &semaphores[i])) catch @panic("failed to create semaphore");
    }

    return .{
        .handle = swapchain,
        .images = swapchain_images,
        .render_semaphores = semaphores,
        .image_views = swapchain_image_views,
        .format = format,
        .extent = extent,
        .attachments = Attachments.init(
            allocs.vma,
            opts.physical_device,
            opts.logical_device,
            extent,
            opts.alloc_cb,
        ),
        // .depth_resource = depth_resource,
    };
}

pub fn deinit(self: *@This(), allocs: core.engine.Allocators, device: vk.Device, vk_alloc_cbs: ?*vk.AllocationCallbacks) void {
    for (self.framebuffers) |fb| {
        vk.DestroyFramebuffer(device, fb, vk_alloc_cbs);
    }

    for (self.image_views) |iv| {
        vk.DestroyImageView(device, iv, vk_alloc_cbs);
    }

    for (self.render_semaphores) |s| {
        vk.DestroySemaphore(device, s, vk_alloc_cbs);
    }

    self.attachments.deinit(allocs.vma, device, vk_alloc_cbs);

    allocs.std.free(self.images);
    allocs.std.free(self.image_views);
    allocs.std.free(self.framebuffers);
    allocs.std.free(self.render_semaphores);

    vk.DestroySwapchainKHR(device, self.handle, vk_alloc_cbs);
}

pub fn recreate(
    self: *@This(),
    allocs: core.engine.Allocators,
    opts: CreateOpts,
    window: *sdl.Window,
    render_pass: vk.RenderPass,
    vk_alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    var width: c_int, var height: c_int = .{ undefined, undefined };
    core.bindings.sdl_usage.checkSdl(sdl.GetWindowSize(window, &width, &height));
    while (width == 0 or height == 0) {
        core.bindings.sdl_usage.checkSdl(sdl.GetWindowSize(window, &width, &height));
    }
    _ = vk.DeviceWaitIdle(opts.logical_device);

    const new_swapchain = Swapchain.create(allocs, opts) catch @panic("failed to create swapchain in recreate fn!");
    self.deinit(allocs, opts.logical_device, vk_alloc_cbs);
    self.* = new_swapchain;
    self.createFramebuffers(
        allocs.std,
        opts.logical_device,
        render_pass,
        opts.alloc_cb,
    ) catch @panic("Failed to create framebuffers");
}

pub fn createFramebuffers(
    self: *@This(),
    a: Allocator,
    device: vk.Device,
    render_pass: vk.RenderPass,
    vk_alloc_cbs: ?*vk.AllocationCallbacks,
) !void {
    const framebuffers = try a.alloc(vk.Framebuffer, self.image_views.len);
    errdefer a.free(framebuffers);

    for (0..self.image_views.len) |i| {
        const attachments = Attachments.imageViews(&self.attachments, self.image_views[i]);
        // const attachments = &if (self.depth_resource) |r|
        //     [_]vk.ImageView{ self.image_views[i], r.view }
        // else
        //     [_]vk.ImageView{self.image_views[i]};

        const ci = vk.FramebufferCreateInfo{
            .sType = vk.STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
            .renderPass = render_pass,
            .attachmentCount = @as(u32, @intCast(attachments.len)),
            .pAttachments = &attachments,
            .width = self.extent.width,
            .height = self.extent.height,
            .layers = 1,
        };
        checkVk(vk.CreateFramebuffer(device, &ci, vk_alloc_cbs, &framebuffers[i])) catch @panic("failed to create framebuffer");
    }

    self.framebuffers = framebuffers;
}

fn createImageView(
    device: vk.Device,
    image: vk.Image,
    format: vk.Format,
    aspect_flags: vk.ImageAspectFlags,
    alloc_cb: ?*vk.AllocationCallbacks,
) vki.VkError!vk.ImageView {
    const view_info = vk.ImageViewCreateInfo{
        .sType = vk.STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = image,
        .viewType = vk.IMAGE_VIEW_TYPE_2D,
        .format = format,
        .components = .{
            .r = vk.COMPONENT_SWIZZLE_IDENTITY,
            .g = vk.COMPONENT_SWIZZLE_IDENTITY,
            .b = vk.COMPONENT_SWIZZLE_IDENTITY,
            .a = vk.COMPONENT_SWIZZLE_IDENTITY,
        },
        .subresourceRange = .{
            .aspectMask = aspect_flags,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };

    var image_view: vk.ImageView = undefined;
    try checkVk(vk.CreateImageView(device, &view_info, alloc_cb, &image_view));
    return image_view;
}

pub const SupportInfo = struct {
    capabilities: vk.SurfaceCapabilitiesKHR = undefined,
    formats: []vk.SurfaceFormatKHR = &.{},
    present_modes: []vk.PresentModeKHR = &.{},

    pub fn init(a: Allocator, device: vk.PhysicalDevice, surface: vk.SurfaceKHR) (vki.VkError || Allocator.Error)!@This() {
        var capabilities: vk.SurfaceCapabilitiesKHR = undefined;
        try checkVk(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(device, surface, &capabilities));

        var format_count: u32 = undefined;
        try checkVk(vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, null));
        const formats = try a.alloc(vk.SurfaceFormatKHR, format_count);
        try checkVk(vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, formats.ptr));

        var present_mode_count: u32 = undefined;
        try checkVk(vk.GetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, null));
        const present_modes = try a.alloc(vk.PresentModeKHR, present_mode_count);
        try checkVk(vk.GetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, present_modes.ptr));

        return .{
            .capabilities = capabilities,
            .formats = formats,
            .present_modes = present_modes,
        };
    }

    pub fn deinit(self: *const @This(), a: Allocator) void {
        a.free(self.formats);
        a.free(self.present_modes);
    }

    fn pickSwapchainFormat(self: *const @This(), opts: CreateOpts) vk.Format {
        // TODO: Add support for specifying desired format.
        _ = opts;
        for (self.formats) |format| {
            if (format.format ==
                vk.FORMAT_R16G16B16A16_SFLOAT
                    // vk.FORMAT_B8G8R8A8_SRGB
            and
                format.colorSpace == vk.COLOR_SPACE_SRGB_NONLINEAR_KHR)
            {
                return format.format;
            }
        }

        return self.formats[0].format;
    }

    fn pickSwapchainPresentMode(self: *const @This(), opts: CreateOpts) vk.PresentModeKHR {
        if (opts.vsync == false) {
            // Prefer immediate mode if present.
            for (self.present_modes) |mode| {
                if (mode == vk.PRESENT_MODE_IMMEDIATE_KHR) {
                    return mode;
                }
            }
            log.info("Immediate present mode is not possible. Falling back to vsync", .{});
        }

        // Prefer triple buffering if possible.
        for (self.present_modes) |mode| {
            if (mode == vk.PRESENT_MODE_MAILBOX_KHR and opts.triple_buffer) {
                return mode;
            }
        }

        // If nothing else is present, FIFO is guaranteed to be available by the specs.
        return vk.PRESENT_MODE_FIFO_KHR;
    }

    fn makeSwapchainExtent(self: *const @This(), opts: CreateOpts) vk.Extent2D {
        if (self.capabilities.currentExtent.width != std.math.maxInt(u32)) {
            return self.capabilities.currentExtent;
        }

        var extent = vk.Extent2D{
            .width = opts.window_width,
            .height = opts.window_height,
        };

        const min_support_w, const max_support_w = .{
            self.capabilities.minImageExtent.width,
            self.capabilities.maxImageExtent.width,
        };
        const min_support_h, const max_support_h = .{
            self.capabilities.minImageExtent.height,
            self.capabilities.maxImageExtent.height,
        };

        extent.width = @min(@max(extent.width, min_support_w), max_support_w);
        extent.height = @min(@max(extent.height, min_support_h), max_support_h);

        return extent;
    }
};
