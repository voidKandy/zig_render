const std = @import("std");
const log = std.log;
const core = @import("core");
const vulkan_init = core.vulkan_init;
const c = core.clibs;
const vk = c.vk;
const checkVk = vulkan_init.checkVk;
const sdl = c.sdl;
const VkError = core.vulkan_init.VkError;

const Vertex = struct {
    pos: core.math.Vec2,
    color: core.math.Vec3,

    fn getBindingDescription() vk.VertexInputBindingDescription {
        return .{
            .binding = 0,
            .stride = @sizeOf(@This()),
            .inputRate = vk.VERTEX_INPUT_RATE_VERTEX,
        };
    }

    /// An attribute description struct describes how to extract a vertex attribute from a chunk of vertex data originating from a binding description.
    /// We have two attributes, position and color, so we need two attribute description structs.
    fn getAttributeDescriptions() [2]vk.VertexInputAttributeDescription {
        return .{
            vk.VertexInputAttributeDescription{
                .binding = 0,
                .location = 0,
                .format = vk.FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(@This(), "pos"),
            },
            vk.VertexInputAttributeDescription{
                .binding = 0,
                .location = 1,
                .format = vk.FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(@This(), "color"),
            },
        };
    }
};

fn debugCallback(sev: vk.DebugUtilsMessageSeverityFlagBitsEXT, typ: vk.DebugUtilsMessageTypeFlagsEXT, cb_data: [*c]const vk.DebugUtilsMessengerCallbackDataEXT, user_data: ?*anyopaque) bool {
    _ = .{ sev, typ, user_data };
    log.warn(
        \\ Validation Layer: {s}
        \\
    , .{cb_data.*.pMessage});
    return false;
}

const MAX_FRAMES_IN_FLIGHT: usize = 2;

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        @panic("Leaked memory");
    };

    var cwd_buff: [1024]u8 = undefined;
    const cwd = std.process.getCwd(cwd_buff[0..]) catch @panic("cwd_buff too small");
    std.log.info("Running from: {s}", .{cwd});

    // var app = HelloTriangleAppliation.init(gpa.allocator());
    // defer app.deinit();
    //
    var engine = core.NewVulkanEngine.init(gpa.allocator());
    defer engine.deinit();

    engine.run();
}

fn checkSdl(res: bool) void {
    if (!res) {
        log.err("Detected SDL error: {s}", .{sdl.GetError()});
        @panic("SDL error");
    }
}

/// Panics if returned bool == false
fn checkSdlBool(res: bool) void {
    if (!res) {
        log.err("Detected SDL error: {s}", .{sdl.GetError()});
        @panic("SDL error");
    }
}

fn createDebugUtilsMessengerEXT(instance: vk.Instance, create_info: vk.DebugUtilsMessengerCreateInfoEXT, alloc_callbacks: *vk.AllocationCallbacks, debug_messenger: *vk.DebugUtilsMessengerEXT) VkError!void {
    const func_opt = vk.GetInstanceProcAddr(instance, "vkCreateDebugUtilsMessengerEXT");
    if (func_opt) |func| {
        return func(instance, create_info, alloc_callbacks, debug_messenger);
    }
    return VkError.ErrorExtensionNotPresent;
}

fn destroyDebugUtilsMessengerEXT(
    instance: vk.Instance,
    debug_messenger: vk.DebugUtilsMessengerEXT,
    alloc_callbacks: ?*vk.AllocationCallbacks,
) void {
    // light wrapper,  we need to migrate to using all the functionality vulkan_init gives us
    const func_opt = vulkan_init.getDestroyDebugUtilsMessengerFn(instance);
    if (func_opt) |func| {
        func(instance, debug_messenger, alloc_callbacks);
    }
}

/// Assumes validation layers are enabled
const HelloTriangleAppliation = struct {
    const Self = @This();
    const vk_alloc_cbs: ?*vk.AllocationCallbacks = null;
    const window_extent = vk.Extent2D{ .width = 1600, .height = 900 };

    allocator: std.mem.Allocator,

    window: *sdl.Window = undefined,

    instance: vk.Instance = undefined,
    debug_messenger: vk.DebugUtilsMessengerEXT = undefined,
    surface: vk.SurfaceKHR = undefined,

    physical_device: vulkan_init.PhysicalDevice = undefined,
    device: vk.Device = undefined,
    vma_allocator: c.vma.Allocator = undefined,

    graphics_queue: vk.Queue = undefined,
    present_queue: vk.Queue = undefined,

    swapchain: vk.SwapchainKHR = undefined,
    swapchain_images: std.ArrayList(vk.Image),
    swapchain_img_format: vk.Format = undefined,
    swapchain_extent: vk.Extent2D = undefined,
    swapchain_image_views: std.ArrayList(vk.ImageView),
    swapchain_framebuffers: std.ArrayList(vk.Framebuffer),

    render_pass: vk.RenderPass = undefined,
    pipeline_layout: vk.PipelineLayout = undefined,
    pipeline: vk.Pipeline = undefined,

    vertex_buffer: vk.Buffer = undefined,

    command_pool: vk.CommandPool = undefined,
    command_buffers: std.ArrayList(vk.CommandBuffer),

    /// Per In-Flight Frame
    image_available_semaphores: std.ArrayList(vk.Semaphore),
    frame_fences: std.ArrayList(vk.Fence),
    /// Per Swapchain Image
    render_finished_semaphores: std.ArrayList(vk.Semaphore),

    current_frame: u32 = 0,
    framebuffer_resized: bool = false,

    fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .swapchain_images = std.ArrayList(vk.Image){},
            .swapchain_image_views = std.ArrayList(vk.ImageView){},
            .swapchain_framebuffers = std.ArrayList(vk.Framebuffer){},
            .command_buffers = std.ArrayList(vk.CommandBuffer){},
            .image_available_semaphores = std.ArrayList(vk.Semaphore){},
            .render_finished_semaphores = std.ArrayList(vk.Semaphore){},
            .frame_fences = std.ArrayList(vk.Fence){},
        };
    }

    fn deinit(self: *Self) void {
        self.cleanupSwapchain();

        vk.DestroyBuffer(self.device, self.vertex_buffer, null);

        vk.DestroyPipeline(self.device, self.pipeline, null);
        vk.DestroyPipelineLayout(self.device, self.pipeline_layout, null);

        vk.DestroyRenderPass(self.device, self.render_pass, null);

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            vk.DestroySemaphore(self.device, self.image_available_semaphores.items[i], null);
            vk.DestroyFence(self.device, self.frame_fences.items[i], null);
        }

        for (0..self.swapchain_images.items.len) |i| {
            vk.DestroySemaphore(self.device, self.render_finished_semaphores.items[i], null);
        }

        self.swapchain_images.deinit(self.allocator);
        self.swapchain_image_views.deinit(self.allocator);
        self.swapchain_framebuffers.deinit(self.allocator);
        self.command_buffers.deinit(self.allocator);
        self.image_available_semaphores.deinit(self.allocator);
        self.render_finished_semaphores.deinit(self.allocator);
        self.frame_fences.deinit(self.allocator);

        vk.DestroyCommandPool(self.device, self.command_pool, null);

        c.vma.DestroyAllocator(self.vma_allocator);
        vk.DestroyDevice(self.device, null);

        // if (self.enable_validation_layers) {
        destroyDebugUtilsMessengerEXT(self.instance, self.debug_messenger, null);
        // }

        vk.DestroySurfaceKHR(self.instance, self.surface, null);
        vk.DestroyInstance(self.instance, null);

        sdl.DestroyWindow(self.window);
        sdl.Quit();
    }

    fn run(self: *Self) void {
        self.initWindow();
        self.initVulkan();

        var quit = false;
        var event: c.sdl.Event = undefined;
        while (!quit) {
            while (c.sdl.PollEvent(&event)) {
                if (event.type == c.sdl.EVENT_QUIT)
                    quit = true
                else
                    self.drawFrame();
            }
        }

        _ = vk.DeviceWaitIdle(self.device);
    }

    fn initWindow(self: *Self) void {
        checkSdl(sdl.Init(sdl.INIT_VIDEO));
        const window = sdl.CreateWindow("Vulkan", window_extent.width, window_extent.height, sdl.WINDOW_VULKAN | sdl.WINDOW_RESIZABLE) orelse @panic("Failed to create SDL window");
        self.window = window;
    }

    fn initVulkan(self: *Self) void {
        self.createInstance();

        // surface creation
        checkSdlBool(sdl.Vulkan_CreateSurface(self.window, self.instance, vk_alloc_cbs, &self.surface));

        // Physical device creation
        const required_device_extensions: []const [*c]const u8 = &.{c.vk.KHR_SWAPCHAIN_EXTENSION_NAME};
        const physical_device = vulkan_init.selectPhysicalDevice(self.allocator, self.instance, .{
            .min_api_version = c.vk.MAKE_VERSION(1, 1, 0),
            .required_extensions = required_device_extensions,
            .surface = self.surface,
            .criteria = .PreferDiscrete,
        }) catch @panic("failed to select physical device");
        self.physical_device = physical_device;

        // logical device creation
        const shader_draw_parameters_features = std.mem.zeroInit(c.vk.PhysicalDeviceShaderDrawParametersFeatures, .{
            .sType = c.vk.STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_DRAW_PARAMETERS_FEATURES,
            .shaderDrawParameters = c.vk.TRUE,
        });
        const logical_device = vulkan_init.createLogicalDevice(self.allocator, .{
            .physical_device = self.physical_device,
            .features = std.mem.zeroInit(c.vk.PhysicalDeviceFeatures, .{}),
            .alloc_cb = vk_alloc_cbs,
            .pnext = &shader_draw_parameters_features,
        }) catch @panic("Failed to create logical device");
        // eventually we should move to using the vulkan_init.Device abstraction because it encapsulates queues, features, etc
        self.device = logical_device.handle;
        self.graphics_queue = logical_device.graphics_queue;
        self.present_queue = logical_device.present_queue;

        // allocator
        const allocator_ci = std.mem.zeroInit(c.vma.AllocatorCreateInfo, .{
            .physicalDevice = self.physical_device.handle,
            .device = self.device,
            .instance = self.instance,
        });
        checkVk(c.vma.CreateAllocator(&allocator_ci, &self.vma_allocator)) catch @panic("Failed to create VMA allocator");

        self.createSwapchain();
        self.createImageViews();
        self.createRenderPass();
        self.createGraphicsPipeline();
        self.createFramebuffers();
        self.createCommandPool();
        self.createVertexBuffer();
        self.createCommandBuffers();
        self.createSyncObjects();
    }

    /// **Does not** deinit up array lists associated with swapchain
    fn cleanupSwapchain(self: *Self) void {
        for (self.swapchain_framebuffers.items) |fb| {
            vk.DestroyFramebuffer(self.device, fb, null);
        }

        for (self.swapchain_image_views.items) |iv| {
            vk.DestroyImageView(self.device, iv, null);
        }

        vk.DestroySwapchainKHR(self.device, self.swapchain, null);
    }

    fn recreateSwapchain(self: *Self) void {
        log.warn(
            \\ Recreating Swapchain!
            \\
        , .{});
        var width: c_int, var height: c_int = .{ undefined, undefined };
        checkSdlBool(sdl.GetWindowSize(self.window, &width, &height));
        while (width == 0 or height == 0) {
            checkSdlBool(sdl.GetWindowSize(self.window, &width, &height));
        }

        _ = vk.DeviceWaitIdle(self.device);

        self.cleanupSwapchain();

        self.createSwapchain();
        self.createImageViews();
        self.createFramebuffers();
    }

    fn createInstance(self: *Self) void {
        var sdl_required_extension_count: u32 = undefined;
        const sdl_extensions = sdl.Vulkan_GetInstanceExtensions(&sdl_required_extension_count);
        const sdl_extension_slice = sdl_extensions[0..sdl_required_extension_count];

        // Instance creation and optional debug utilities
        const instance = vulkan_init.createInstance(std.heap.page_allocator, .{
            .application_name = "VkGuide",
            .application_version = c.vk.MAKE_VERSION(0, 1, 0),
            .engine_name = "VkGuide",
            .engine_version = c.vk.MAKE_VERSION(0, 1, 0),
            .api_version = c.vk.MAKE_VERSION(1, 1, 0),
            .debug = true,
            .required_extensions = sdl_extension_slice,
        }) catch |err| {
            log.err("Failed to create vulkan instance with error: {s}", .{@errorName(err)});
            unreachable;
        };

        self.instance = instance.handle;
        self.debug_messenger = instance.debug_messenger;
    }

    fn chooseSwapExtent(self: Self, swapchain_support_details: SwapChainSupportDetails) vk.Extent2D {
        if (swapchain_support_details.capabilities.currentExtent.width != std.math.maxInt(u32))
            return swapchain_support_details.capabilities.currentExtent;

        var width: c_int, var height: c_int = .{ undefined, undefined };

        checkSdlBool(sdl.GetWindowSize(self.window, &width, &height));

        const min_support_w, const max_support_w = .{
            swapchain_support_details.capabilities.minImageExtent.width,
            swapchain_support_details.capabilities.maxImageExtent.width,
        };
        const min_support_h, const max_support_h = .{
            swapchain_support_details.capabilities.minImageExtent.height,
            swapchain_support_details.capabilities.maxImageExtent.height,
        };

        // clamping width and height to be within capabilities' min/max
        const actual_extent = vk.Extent2D{
            .width = @min(@max(width, min_support_w), max_support_w),
            .height = @min(@max(height, min_support_h), max_support_h),
        };

        return actual_extent;
    }

    fn querySwapchainSupport(allocator: std.mem.Allocator, device: vk.PhysicalDevice, surface: vk.SurfaceKHR) VkError!SwapChainSupportDetails {
        var details = SwapChainSupportDetails{};
        try checkVk(vk.GetPhysicalDeviceSurfaceCapabilitiesKHR(device, surface, &details.capabilities));
        var format_count: u32 = undefined;
        try checkVk(vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, null));

        if (format_count > 0) {
            details.formats.resize(allocator, format_count) catch @panic("out of memory");
            try checkVk(vk.GetPhysicalDeviceSurfaceFormatsKHR(device, surface, &format_count, details.formats.items.ptr));
        }

        var present_mode_count: u32 = undefined;
        try checkVk(vk.GetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, null));
        if (present_mode_count > 0) {
            details.present_modes.resize(allocator, present_mode_count) catch @panic("out of memory");
            try checkVk(vk.GetPhysicalDeviceSurfacePresentModesKHR(device, surface, &present_mode_count, details.present_modes.items.ptr));
        }

        return details;
    }

    fn createSwapchain(self: *Self) void {
        var details = querySwapchainSupport(self.allocator, self.physical_device.handle, self.surface) catch @panic("failed to get swapchain support details");
        defer details.deinit(self.allocator);

        const surface_format = details.chooseSurfaceFormat();
        const present_mode = details.choosePresentMode();
        const extent = self.chooseSwapExtent(details);

        var image_count: u32 =
            details.capabilities.minImageCount + 1;
        if (details.capabilities.maxImageCount > 0 and image_count > details.capabilities.maxImageCount)
            image_count = details.capabilities.maxImageCount;

        var ci = vk.SwapchainCreateInfoKHR{
            .sType = vk.STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .minImageCount = image_count,
            .imageFormat = surface_format.format,
            .imageColorSpace = surface_format.colorSpace,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = vk.IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .surface = self.surface,
        };

        const indices = QueueFamilyIndices.findQueueFamilies(self.allocator, self.physical_device.handle, self.surface) catch @panic("failed to find queue families");
        const queue_family_indices = [_]u32{ indices.graphics_family.?, indices.present_family.? };

        if (indices.graphics_family != indices.present_family) {
            ci.imageSharingMode = vk.SHARING_MODE_CONCURRENT;
            ci.queueFamilyIndexCount = 2;
            ci.pQueueFamilyIndices = &queue_family_indices;
        } else {
            ci.imageSharingMode = vk.SHARING_MODE_EXCLUSIVE;
        }

        ci.preTransform = details.capabilities.currentTransform;
        ci.compositeAlpha = vk.COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
        ci.presentMode = present_mode;
        ci.clipped = vk.TRUE;

        checkVk(vk.CreateSwapchainKHR(self.device, &ci, null, &self.swapchain)) catch
            @panic("failed to create swapchain");

        checkVk(vk.GetSwapchainImagesKHR(self.device, self.swapchain, &image_count, null)) catch
            @panic("failed to get swapchain images count");

        self.swapchain_images.resize(self.allocator, image_count) catch @panic("could not resize sc images");

        checkVk(vk.GetSwapchainImagesKHR(self.device, self.swapchain, &image_count, self.swapchain_images.items.ptr)) catch
            @panic("failed to get swapchain images");

        self.swapchain_img_format = surface_format.format;
        self.swapchain_extent = extent;
    }

    fn createImageViews(self: *Self) void {
        self.swapchain_image_views.resize(self.allocator, self.swapchain_images.items.len) catch @panic("could not resize sc image views");

        for (0..self.swapchain_images.items.len) |i| {
            const ci = vk.ImageViewCreateInfo{
                .sType = vk.STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .image = self.swapchain_images.items[i],
                .viewType = vk.IMAGE_VIEW_TYPE_2D,
                .format = self.swapchain_img_format,
                .components = .{
                    .r = vk.COMPONENT_SWIZZLE_IDENTITY,
                    .g = vk.COMPONENT_SWIZZLE_IDENTITY,
                    .b = vk.COMPONENT_SWIZZLE_IDENTITY,
                    .a = vk.COMPONENT_SWIZZLE_IDENTITY,
                },
                .subresourceRange = .{
                    .aspectMask = vk.IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },
            };

            checkVk(vk.CreateImageView(self.device, &ci, null, &self.swapchain_image_views.items[i])) catch |e| {
                log.err(
                    \\ Failed to create image view: {s}
                , .{@errorName(e)});
                @panic("failed to create image view");
            };
        }
    }

    fn createRenderPass(self: *Self) void {
        const color_attachment = vk.AttachmentDescription{
            .format = self.swapchain_img_format,
            .samples = vk.SAMPLE_COUNT_1_BIT,
            .loadOp = vk.ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = vk.ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = vk.ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = vk.IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = vk.IMAGE_LAYOUT_PRESENT_SRC_KHR,
        };

        const color_attachment_ref = vk.AttachmentReference{
            .attachment = 0,
            .layout = vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };

        const subpass = vk.SubpassDescription{
            .pipelineBindPoint = vk.PIPELINE_BIND_POINT_GRAPHICS,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_attachment_ref,
        };

        const dependency = vk.SubpassDependency{
            .srcSubpass = vk.SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = 0,
            .dstStageMask = vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstAccessMask = vk.ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        };

        const ci = vk.RenderPassCreateInfo{
            .sType = vk.STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .attachmentCount = 1,
            .pAttachments = &color_attachment,
            .subpassCount = 1,
            .pSubpasses = &subpass,
            .dependencyCount = 1,
            .pDependencies = &dependency,
        };

        checkVk(vk.CreateRenderPass(self.device, &ci, null, &self.render_pass)) catch @panic("failed to create render pass");
    }

    /// This being a better language than C/C++, means we don´t need to load
    /// the SPIR-V code from a file, we can just embed it as an array of bytes.
    fn createShaderModule(self: *Self, code: []const u8) ?c.vk.ShaderModule {
        std.debug.assert(code.len % 4 == 0);

        const data: *const u32 = @ptrCast(@alignCast(code.ptr));

        const shader_module_ci = std.mem.zeroInit(c.vk.ShaderModuleCreateInfo, .{
            .sType = c.vk.STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
            .codeSize = code.len,
            .pCode = data,
        });

        var shader_module: c.vk.ShaderModule = undefined;
        checkVk(c.vk.CreateShaderModule(self.device, &shader_module_ci, vk_alloc_cbs, &shader_module)) catch |err| {
            log.err("Failed to create shader module with error: {s}", .{@errorName(err)});
            return null;
        };

        return shader_module;
    }

    fn createGraphicsPipeline(self: *Self) void {
        const bindingDescription = Vertex.getBindingDescription();
        const attributeDescriptions = Vertex.getAttributeDescriptions();

        const vert_shader = core.shaders.createShaderModule("triangle.vert", self.device, null) orelse @panic("failed to create vert shader module");
        defer vk.DestroyShaderModule(self.device, vert_shader, null);
        const frag_shader = core.shaders.createShaderModule("triangle.frag", self.device, null) orelse @panic("failed to create frag shader module");
        defer vk.DestroyShaderModule(self.device, frag_shader, null);

        const vert_stage_ci = vk.PipelineShaderStageCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = vk.SHADER_STAGE_VERTEX_BIT,
            .module = vert_shader,
            .pName = "main",
        };
        const frag_stage_ci = vk.PipelineShaderStageCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
            .stage = vk.SHADER_STAGE_FRAGMENT_BIT,
            .module = frag_shader,
            .pName = "main",
        };

        const shader_stages = [_]vk.PipelineShaderStageCreateInfo{ vert_stage_ci, frag_stage_ci };

        const vertex_input_info = vk.PipelineVertexInputStateCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO,
            .vertexBindingDescriptionCount = 1,
            .pVertexBindingDescriptions = &bindingDescription,
            .vertexAttributeDescriptionCount = attributeDescriptions.len,
            .pVertexAttributeDescriptions = &attributeDescriptions,
        };

        const input_assembly = vk.PipelineInputAssemblyStateCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO,
            .topology = vk.PRIMITIVE_TOPOLOGY_TRIANGLE_LIST,
            .primitiveRestartEnable = vk.FALSE,
        };

        const viewport_state = vk.PipelineViewportStateCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO,
            .viewportCount = 1,
            .scissorCount = 1,
        };

        const rasterizer = vk.PipelineRasterizationStateCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO,
            .depthClampEnable = vk.FALSE,
            .rasterizerDiscardEnable = vk.FALSE,
            .polygonMode = vk.POLYGON_MODE_FILL,
            .lineWidth = 1.0,
            .cullMode = vk.CULL_MODE_BACK_BIT,
            .frontFace = vk.FRONT_FACE_CLOCKWISE,
            .depthBiasEnable = vk.FALSE,
        };

        const multisampling = vk.PipelineMultisampleStateCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO,
            .sampleShadingEnable = vk.FALSE,
            .rasterizationSamples = vk.SAMPLE_COUNT_1_BIT,
        };

        const color_blend_attachment = vk.PipelineColorBlendAttachmentState{
            .colorWriteMask = vk.COLOR_COMPONENT_R_BIT | vk.COLOR_COMPONENT_G_BIT | vk.COLOR_COMPONENT_B_BIT | vk.COLOR_COMPONENT_A_BIT,
            .blendEnable = vk.FALSE,
        };

        const color_blending = vk.PipelineColorBlendStateCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO,
            .logicOpEnable = vk.FALSE,
            .logicOp = vk.LOGIC_OP_COPY,
            .attachmentCount = 1,
            .pAttachments = &color_blend_attachment,
            .blendConstants = [4]f32{ 0.0, 0.0, 0.0, 0.0 },
        };

        const dynamic_states = [_]vk.DynamicState{
            vk.DYNAMIC_STATE_VIEWPORT,
            vk.DYNAMIC_STATE_SCISSOR,
        };

        const dynamic_state = vk.PipelineDynamicStateCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO,
            .dynamicStateCount = @as(u32, @intCast(dynamic_states.len)),
            .pDynamicStates = &dynamic_states,
        };
        const pipeline_layout_ci = vk.PipelineLayoutCreateInfo{
            .sType = vk.STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .setLayoutCount = 0,
            .pushConstantRangeCount = 0,
        };

        checkVk(vk.CreatePipelineLayout(self.device, &pipeline_layout_ci, null, &self.pipeline_layout)) catch
            @panic("failed to create pipeline layout");

        const pipeline_ci = vk.GraphicsPipelineCreateInfo{
            .sType = vk.STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO,
            .stageCount = 2,
            .pStages = &shader_stages,
            .pVertexInputState = &vertex_input_info,
            .pInputAssemblyState = &input_assembly,
            .pViewportState = &viewport_state,
            .pRasterizationState = &rasterizer,
            .pMultisampleState = &multisampling,
            .pColorBlendState = &color_blending,
            .pDynamicState = &dynamic_state,
            .layout = self.pipeline_layout,
            .renderPass = self.render_pass,
            .subpass = 0,
            .basePipelineHandle = null,
        };

        checkVk(vk.CreateGraphicsPipelines(self.device, null, 1, &pipeline_ci, null, &self.pipeline)) catch
            @panic("failed to create graphics pipeline");
    }

    fn createFramebuffers(self: *Self) void {
        self.swapchain_framebuffers.resize(self.allocator, self.swapchain_image_views.items.len) catch @panic("out of memory");

        for (0..self.swapchain_image_views.items.len) |i| {
            const attachments = [_]vk.ImageView{self.swapchain_image_views.items[i]};
            const ci = vk.FramebufferCreateInfo{
                .sType = vk.STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                .renderPass = self.render_pass,
                .attachmentCount = 1,
                .pAttachments = &attachments[0],
                .width = self.swapchain_extent.width,
                .height = self.swapchain_extent.height,
                .layers = 1,
            };
            checkVk(vk.CreateFramebuffer(self.device, &ci, null, &self.swapchain_framebuffers.items[i])) catch @panic("failed to create framebuffer");
        }
    }

    fn createVertexBuffer(self: *Self) void {
        const vertices = [_]Vertex{
            .{
                .pos = core.math.Vec2.make(0.0, -0.5),
                .color = core.math.Vec3.make(1.0, 0.0, 0.0),
            },
            .{
                .pos = core.math.Vec2.make(0.5, 0.5),
                .color = core.math.Vec3.make(0.0, 1.0, 0.0),
            },
            .{
                .pos = core.math.Vec2.make(-0.5, 0.5),
                .color = core.math.Vec3.make(0.0, 0.0, 1.0),
            },
        };

        const ci = vk.BufferCreateInfo{
            .sType = vk.STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .usage = vk.BUFFER_USAGE_VERTEX_BUFFER_BIT,
            .sharingMode = vk.SHARING_MODE_EXCLUSIVE,
            .size = @sizeOf(Vertex) * vertices.len,
        };

        const mem_requirements: vk.MemoryRequirements = undefined;
        vk.GetBufferMemoryRequirements(self.device, self.vertex_buffer, &mem_requirements);

        const ai = vk.MemoryAllocateInfo{
            .sType = vk.STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .allocationSize = mem_requirements.size,
            .memoryTypeIndex = core.vma_usage.findMemoryType(mem_requirements.memoryTypeBits, vk.MEMORY_PROPERTY_HOST_VISIBLE_BIT | vk.MEMORY_PROPERTY_HOST_COHERENT_BIT),
        };

        var staging_buffer: core.vma_usage.AllocatedBuffer = undefined;
        checkVk(c.vma.CreateBuffer(self.vma_allocator, &ci, &ai, &staging_buffer.buffer, &staging_buffer.allocation, null)) catch @panic("Failed to create vertex buffer");
    }

    fn createCommandPool(self: *Self) void {
        const indices = QueueFamilyIndices.findQueueFamilies(self.allocator, self.physical_device.handle, self.surface) catch @panic("failed to find queue families");

        const ci = vk.CommandPoolCreateInfo{
            .sType = vk.STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = vk.COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = indices.graphics_family.?,
        };

        checkVk(vk.CreateCommandPool(self.device, &ci, null, &self.command_pool)) catch @panic("failed to create command pool");
    }

    fn createCommandBuffers(self: *Self) void {
        self.command_buffers.resize(self.allocator, MAX_FRAMES_IN_FLIGHT) catch @panic("out of memory");

        const alloc_info = vk.CommandBufferAllocateInfo{
            .sType = vk.STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = self.command_pool,
            .level = vk.COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = @as(u32, @intCast(self.command_buffers.items.len)),
        };

        checkVk(vk.AllocateCommandBuffers(self.device, &alloc_info, &self.command_buffers.items[0])) catch @panic("failed to allocate command buffers");
    }

    fn recordCommandBuffers(self: *Self, command_buffer: vk.CommandBuffer, image_idx: u32) void {
        var begin_info = vk.CommandBufferBeginInfo{
            .sType = vk.STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        };

        checkVk(vk.BeginCommandBuffer(command_buffer, &begin_info)) catch @panic("failed to begin command buffer");

        var render_pass_info = vk.RenderPassBeginInfo{
            .sType = vk.STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .renderPass = self.render_pass,
            .framebuffer = self.swapchain_framebuffers.items[image_idx],
            .renderArea = .{ .offset = .{
                .x = 0,
                .y = 0,
            }, .extent = self.swapchain_extent },
        };
        const clear_color = vk.ClearValue{
            .color = .{ .float32 = .{0} ** 4 },
        };

        render_pass_info.clearValueCount = 1;
        render_pass_info.pClearValues = &clear_color;

        {
            vk.CmdBeginRenderPass(command_buffer, &render_pass_info, vk.SUBPASS_CONTENTS_INLINE);
            defer vk.CmdEndRenderPass(command_buffer);

            vk.CmdBindPipeline(command_buffer, vk.PIPELINE_BIND_POINT_GRAPHICS, self.pipeline);

            const viewport = vk.Viewport{
                .x = 0.0,
                .y = 0.0,
                .width = @floatFromInt(self.swapchain_extent.width),
                .height = @floatFromInt(self.swapchain_extent.height),
                .minDepth = 0.0,
                .maxDepth = 1.0,
            };
            vk.CmdSetViewport(command_buffer, 0, 1, &viewport);

            const scissor = vk.Rect2D{
                .offset = .{ .x = 0, .y = 0 },
                .extent = self.swapchain_extent,
            };
            vk.CmdSetScissor(command_buffer, 0, 1, &scissor);

            // its fine to use the magic number 3 for vertex count because we are only expecting 3 vertices
            // This is not ideal for a generalized system
            vk.CmdDraw(command_buffer, 3, 1, 0, 0);
        }

        checkVk(vk.EndCommandBuffer(command_buffer)) catch @panic("failed to record command buffer");
    }

    fn createSyncObjects(self: *Self) void {
        self.image_available_semaphores.resize(self.allocator, MAX_FRAMES_IN_FLIGHT) catch @panic("out of memory");
        self.frame_fences.resize(self.allocator, MAX_FRAMES_IN_FLIGHT) catch @panic("out of memory");

        self.render_finished_semaphores.resize(self.allocator, self.swapchain_images.items.len) catch @panic("out of memory");

        const semaphore_ci = vk.SemaphoreCreateInfo{
            .sType = vk.STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        };

        const fence_ci = vk.FenceCreateInfo{
            .sType = vk.STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .flags = vk.FENCE_CREATE_SIGNALED_BIT,
        };

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            checkVk(vk.CreateSemaphore(self.device, &semaphore_ci, null, &self.image_available_semaphores.items[i])) catch
                @panic("failed to create image available semaphore");
            checkVk(vk.CreateFence(self.device, &fence_ci, null, &self.frame_fences.items[i])) catch
                @panic("failed to create fence");
        }

        for (0..self.swapchain_images.items.len) |i| {
            checkVk(vk.CreateSemaphore(self.device, &semaphore_ci, null, &self.render_finished_semaphores.items[i])) catch
                @panic("failed to create render finished semaphore");
        }
    }

    fn drawFrame(self: *Self) void {
        const frame_fence =
            self.frame_fences.items[self.current_frame];
        const acquire_semaphore =
            self.image_available_semaphores.items[self.current_frame];

        checkVk(vk.WaitForFences(self.device, 1, &frame_fence, vk.TRUE, std.math.maxInt(u64))) catch @panic("failed to wait for current fence");

        var image_idx: u32 = undefined;
        checkVk(vk.AcquireNextImageKHR(self.device, self.swapchain, std.math.maxInt(u64), acquire_semaphore, null, &image_idx)) catch |e|
            switch (e) {
                VkError.ErrorOutOfDateKHR => {
                    self.recreateSwapchain();
                    return;
                },
                VkError.SuboptimalKHR => {
                    log.warn(
                        \\ Suboptimal KHR!
                        \\
                    , .{});
                },
                else => @panic("failed to acquire next image"),
            };

        const submit_semaphore =
            self.render_finished_semaphores.items[image_idx];

        checkVk(vk.ResetFences(self.device, 1, &frame_fence)) catch @panic("failed to reset fences");
        checkVk(vk.ResetCommandBuffer(self.command_buffers.items[self.current_frame], 0)) catch @panic("failed to reset command buffers");
        self.recordCommandBuffers(self.command_buffers.items[self.current_frame], image_idx);

        const wait_semaphores = &[_]vk.Semaphore{acquire_semaphore};
        const wait_stages = &[_]vk.PipelineStageFlags{vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
        const signal_semaphores = &[_]vk.Semaphore{submit_semaphore};

        var submit_info = vk.SubmitInfo{
            .sType = vk.STRUCTURE_TYPE_SUBMIT_INFO,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = wait_semaphores,
            .pWaitDstStageMask = wait_stages,
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = signal_semaphores,
            .commandBufferCount = 1,
            .pCommandBuffers = &self.command_buffers.items[self.current_frame],
        };

        checkVk(vk.QueueSubmit(self.graphics_queue, 1, &submit_info, frame_fence)) catch @panic("failed to submit draw command buffer");

        const present_info = vk.PresentInfoKHR{
            .sType = vk.STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = signal_semaphores,
            .swapchainCount = 1,
            .pSwapchains = &[_]vk.SwapchainKHR{self.swapchain},
            .pImageIndices = &image_idx,
        };

        checkVk(vk.QueuePresentKHR(self.present_queue, &present_info)) catch |e| {
            if (e == VkError.ErrorOutOfDateKHR or
                e == VkError.SuboptimalKHR or
                self.framebuffer_resized)
            {
                self.framebuffer_resized = false;
                self.recreateSwapchain();
            } else {
                @panic("failed to present swapchain image");
            }
        };

        self.current_frame = (self.current_frame + 1) % @as(u32, @intCast(MAX_FRAMES_IN_FLIGHT));
        std.debug.assert(self.current_frame < @as(u32, @intCast(MAX_FRAMES_IN_FLIGHT)));
    }
};

const QueueFamilyIndices = struct {
    graphics_family: ?u32 = null,
    present_family: ?u32 = null,

    fn isComplete(self: @This()) bool {
        return self.graphics_family != null and self.present_family != null;
    }

    fn findQueueFamilies(allocator: std.mem.Allocator, device: vk.PhysicalDevice, surface: vk.SurfaceKHR) VkError!@This() {
        var indices = @This(){};

        var queue_fam_count: u32 = 0;

        vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_fam_count, null);
        const queue_families = allocator.alloc(vk.QueueFamilyProperties, queue_fam_count) catch @panic("out of memory");
        defer allocator.free(queue_families);
        vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_fam_count, queue_families.ptr);

        for (queue_families, 0..) |fam, i| {
            if (fam.queueFlags & vk.QUEUE_GRAPHICS_BIT != 0)
                indices.graphics_family = @as(u32, @intCast(i));
            // present support is booly but we need to use an integer
            // I'd rather not define as false and then cast
            var present_support: vk.Bool32 = 0;
            try checkVk(vk.GetPhysicalDeviceSurfaceSupportKHR(device, @as(u32, @intCast(i)), surface, &present_support));

            if (present_support != 0)
                indices.present_family = @as(u32, @intCast(i));

            if (indices.isComplete())
                break;
        }

        return indices;
    }
};

// swapchain stuff, a lot of this logic has no business being inside the triangle application
const SwapChainSupportDetails = struct {
    capabilities: vk.SurfaceCapabilitiesKHR = .{},
    formats: std.ArrayList(vk.SurfaceFormatKHR) = std.ArrayList(vk.SurfaceFormatKHR){},
    present_modes: std.ArrayList(vk.PresentModeKHR) = std.ArrayList(vk.PresentModeKHR){},

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        self.present_modes.deinit(allocator);
        self.formats.deinit(allocator);
    }

    fn chooseSurfaceFormat(self: @This()) vk.SurfaceFormatKHR {
        for (self.formats.items) |format| {
            if (format.format == vk.FORMAT_B8G8R8A8_SRGB and format.colorSpace == vk.COLOR_SPACE_SRGB_NONLINEAR_KHR) {
                return format;
            }
        }
        return self.formats.items[0];
    }

    fn choosePresentMode(self: @This()) vk.PresentModeKHR {
        for (self.present_modes.items) |present| {
            if (present == vk.PRESENT_MODE_MAILBOX_KHR) {
                return present;
            }
        }

        return vk.PRESENT_MODE_FIFO_KHR;
    }
};
