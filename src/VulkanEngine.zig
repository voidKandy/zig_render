const std = @import("std");
const log = std.log.scoped(.vulkan_engine);
const root = @import("root.zig");
const texs = @import("textures.zig");
const vulkan_init = root.vulkan_init;
const vma_usage = root.vma_usage;
const mesh_mod = root.mesh;
const c = root.clibs;
const vk = c.vk;
const checkVk = vulkan_init.checkVk;
const sdl = c.sdl;
const checkSdl = root.checkSdl;
const VkError = root.vulkan_init.VkError;
const UploadContext = root.vulkan_init.UploadContext;
const FrameData = root.vulkan_init.FrameData;
const VulkanDeleter = vma_usage.VulkanDeleter;
const Vec2 = root.math.Vec2;
const Vec3 = root.math.Vec3;
const Mat4 = root.math.Mat4;

const MAX_FRAMES_IN_FLIGHT: usize = 2;

const Self = @This();
const vk_alloc_cbs: ?*vk.AllocationCallbacks = null;
const window_extent = vk.Extent2D{ .width = 1600, .height = 900 };

allocator: std.mem.Allocator,
vma_allocator: c.vma.Allocator = undefined,

window: *sdl.Window = undefined,

instance: vulkan_init.Instance = undefined,
surface: vk.SurfaceKHR = undefined,

physical_device: vulkan_init.PhysicalDevice = undefined,
device: vulkan_init.Device = undefined,

deletion_queue: std.ArrayList(VulkanDeleter) = undefined,
buffer_deletion_queue: std.ArrayList(vma_usage.VmaBufferDeleter) = undefined,
image_deletion_queue: std.ArrayList(vma_usage.VmaImageDeleter) = undefined,

swapchain: vulkan_init.Swapchain = undefined,
framebuffer_resized: bool = false,

render_pass: vk.RenderPass = undefined,
descriptor_set_layout: vk.DescriptorSetLayout = undefined,
pipeline_layout: vk.PipelineLayout = undefined,
pipeline: vk.Pipeline = undefined,

upload_context: vulkan_init.UploadContext = .{},
frames: [MAX_FRAMES_IN_FLIGHT]FrameData = .{FrameData{}} ** MAX_FRAMES_IN_FLIGHT,
current_frame: u32 = 0,

/// eventually these should be string hash maps
meshes: []mesh_mod.Mesh3D = undefined,
texture: texs.Texture = undefined,

texture_sampler: vk.Sampler = undefined,

depth_image: vma_usage.AllocatedImage = undefined,
depth_image_view: vk.ImageView = undefined,

// pretty sure this should live in frameData
uniform_buffers: []vma_usage.AllocatedBuffer = undefined,
uniform_buffers_mapped: []?*anyopaque = undefined,
descriptor_pool: vk.DescriptorPool = undefined,
descriptor_sets: []vk.DescriptorSet = undefined,

pub fn init(a: std.mem.Allocator) Self {
    return .{
        .allocator = a,
        .deletion_queue = std.ArrayList(VulkanDeleter){},
        .buffer_deletion_queue = std.ArrayList(vma_usage.VmaBufferDeleter){},
        .image_deletion_queue = std.ArrayList(vma_usage.VmaImageDeleter){},
    };
}

pub fn deinit(self: *Self) void {
    checkVk(vk.DeviceWaitIdle(self.device.handle)) catch @panic("Failed to wait for device idle");
    self.swapchain.deinit(self.allocator, self.device.handle, vk_alloc_cbs);

    // not using VMA!! should
    // vk.DestroyBuffer(self.device.handle, self.vertex_buffer, vk_alloc_cbs);
    // vk.FreeMemory(self.device.handle, self.vertex_buffer_memory, vk_alloc_cbs);

    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        c.vma.UnmapMemory(self.vma_allocator, self.uniform_buffers[i].allocation);
        c.vma.DestroyBuffer(self.vma_allocator, self.uniform_buffers[i].buffer, self.uniform_buffers[i].allocation);
        self.frames[i].deinit(self.device.handle, vk_alloc_cbs);
    }
    self.allocator.free(self.uniform_buffers);
    self.allocator.free(self.uniform_buffers_mapped);

    vk.DestroyDescriptorPool(self.device.handle, self.descriptor_pool, vk_alloc_cbs);
    vk.DestroyDescriptorSetLayout(self.device.handle, self.descriptor_set_layout, vk_alloc_cbs);
    vk.DestroyPipeline(self.device.handle, self.pipeline, vk_alloc_cbs);
    vk.DestroyPipelineLayout(self.device.handle, self.pipeline_layout, vk_alloc_cbs);

    vk.DestroyRenderPass(self.device.handle, self.render_pass, vk_alloc_cbs);

    for (self.buffer_deletion_queue.items) |*entry| {
        entry.delete(self.vma_allocator);
    }
    self.buffer_deletion_queue.deinit(self.allocator);

    for (self.image_deletion_queue.items) |*entry| {
        entry.delete(self.vma_allocator);
    }
    self.image_deletion_queue.deinit(self.allocator);

    for (self.deletion_queue.items) |*entry| {
        entry.delete(self.device.handle);
    }
    self.deletion_queue.deinit(self.allocator);

    self.allocator.free(self.descriptor_sets);

    vk.DestroySampler(self.device.handle, self.texture_sampler, vk_alloc_cbs);

    // texture should have deinit?
    vk.DestroyImageView(self.device.handle, self.texture.image_view, vk_alloc_cbs);
    c.vma.DestroyImage(self.vma_allocator, self.texture.image.image, self.texture.image.allocation);

    for (0..self.meshes.len) |i| {
        // mesh should have deinit?
        c.vma.DestroyBuffer(self.vma_allocator, self.meshes[i].index_buffer.buffer, self.meshes[i].index_buffer.allocation);
        c.vma.DestroyBuffer(self.vma_allocator, self.meshes[i].vertex_buffer.buffer, self.meshes[i].vertex_buffer.allocation);
        self.allocator.free(self.meshes[i].indices);
        self.allocator.free(self.meshes[i].vertices);
    }
    self.allocator.free(self.meshes);

    c.vma.DestroyAllocator(self.vma_allocator);
    vk.DestroyDevice(self.device.handle, vk_alloc_cbs);

    if (self.instance.debug_messenger != null) {
        const destroy_fn = root.vulkan_init.getDestroyDebugUtilsMessengerFn(self.instance.handle) orelse @panic("Debug messenger present but there is no destroy function?")();
        destroy_fn(self.instance.handle, self.instance.debug_messenger, vk_alloc_cbs);
    }

    vk.DestroySurfaceKHR(self.instance.handle, self.surface, vk_alloc_cbs);
    vk.DestroyInstance(self.instance.handle, vk_alloc_cbs);

    sdl.DestroyWindow(self.window);
    sdl.Quit();
}

pub fn run(self: *Self) void {
    self.initWindow();
    self.initVulkan();

    var quit = false;
    var event: c.sdl.Event = undefined;

    while (!quit) {
        while (c.sdl.PollEvent(&event)) {
            if (event.type == c.sdl.EVENT_QUIT) quit = true;
        }

        self.drawFrame();
    }

    _ = vk.DeviceWaitIdle(self.device.handle);
}

fn initWindow(self: *Self) void {
    checkSdl(sdl.Init(sdl.INIT_VIDEO));
    const window = sdl.CreateWindow("Vulkan", window_extent.width, window_extent.height, sdl.WINDOW_VULKAN | sdl.WINDOW_RESIZABLE) orelse @panic("Failed to create SDL window");
    self.window = window;
}

fn initVulkan(self: *Self) void {
    // Instance creation and optional debug utilities
    var sdl_required_extension_count: u32 = undefined;
    const sdl_extensions = sdl.Vulkan_GetInstanceExtensions(&sdl_required_extension_count);
    const sdl_extension_slice = sdl_extensions[0..sdl_required_extension_count];

    self.instance = vulkan_init.Instance.create(std.heap.page_allocator, .{
        .application_name = "VkGuide",
        .application_version = vk.MAKE_VERSION(0, 1, 0),
        .engine_name = "VkGuide",
        .engine_version = vk.MAKE_VERSION(0, 1, 0),
        .api_version = vk.MAKE_VERSION(1, 1, 0),
        .debug = true,
        .required_extensions = sdl_extension_slice,
    }) catch |err| {
        log.err("Failed to create vulkan instance with error: {s}", .{@errorName(err)});
        unreachable;
    };

    // surface creation
    checkSdl(sdl.Vulkan_CreateSurface(self.window, self.instance.handle, vk_alloc_cbs, &self.surface));

    // Physical device creation
    const required_device_extensions: []const [*c]const u8 = &.{vk.KHR_SWAPCHAIN_EXTENSION_NAME};
    const physical_device = vulkan_init.selectPhysicalDevice(self.allocator, self.instance.handle, .{
        .min_api_version = vk.MAKE_VERSION(1, 1, 0),
        .required_extensions = required_device_extensions,
        .surface = self.surface,
        .criteria = .PreferDiscrete,
    }) catch @panic("failed to select physical device");
    self.physical_device = physical_device;

    // logical device creation
    const shader_draw_parameters_features = vk.PhysicalDeviceShaderDrawParametersFeatures{
        .sType = vk.STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_DRAW_PARAMETERS_FEATURES,
        .shaderDrawParameters = vk.TRUE,
    };
    const logical_device = vulkan_init.createLogicalDevice(self.allocator, .{
        .physical_device = self.physical_device,
        .features = vk.PhysicalDeviceFeatures{
            .samplerAnisotropy = vk.TRUE,
        },
        .alloc_cb = vk_alloc_cbs,
        .pnext = &shader_draw_parameters_features,
    }) catch @panic("Failed to create logical device");
    self.device = logical_device;

    // vma allocator
    const allocator_ci = c.vma.AllocatorCreateInfo{
        .physicalDevice = self.physical_device.handle,
        .device = self.device.handle,
        .instance = self.instance.handle,
    };
    checkVk(c.vma.CreateAllocator(&allocator_ci, &self.vma_allocator)) catch @panic("Failed to create VMA allocator");

    // Swapchain creation
    var win_width: c_int, var win_height: c_int = .{ undefined, undefined };
    checkSdl(c.sdl.GetWindowSize(self.window, &win_width, &win_height));

    self.swapchain = vulkan_init.Swapchain.create(self.allocator, .{
        .physical_device = self.physical_device.handle,
        .graphics_queue_family = self.physical_device.graphics_queue_family,
        .present_queue_family = self.physical_device.present_queue_family,
        .device = self.device.handle,
        .surface = self.surface,
        .old_swapchain = null,
        .vsync = true,
        .window_width = @intCast(win_width),
        .window_height = @intCast(win_height),
        .alloc_cb = vk_alloc_cbs,
    }) catch @panic("failed to create swapchain");

    self.createRenderPass();
    self.createDescriptorSetLayout();
    self.createGraphicsPipeline();

    self.swapchain.createFramebuffers(self.allocator, self.device.handle, vk_alloc_cbs, self.render_pass) catch @panic("failed to create framebuffers");

    self.createCommands();
    self.createSyncObjects();
    self.createDepthResources();
    self.createTextureImage();
    self.createTextureSampler();
    self.createMeshes();
    self.createUniformBuffers();
    self.createDescriptorPool();
    self.createDescriptorSets();
}

fn createRenderPass(self: *Self) void {
    const color_attachment = vk.AttachmentDescription{
        .format = self.swapchain.format,
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

    checkVk(vk.CreateRenderPass(self.device.handle, &ci, vk_alloc_cbs, &self.render_pass)) catch @panic("failed to create render pass");
}

/// This being a better language than C/C++, means we don´t need to load
/// the SPIR-V code from a file, we can just embed it as an array of bytes.
fn createShaderModule(self: *Self, code: []const u8) ?vk.ShaderModule {
    std.debug.assert(code.len % 4 == 0);

    const data: *const u32 = @ptrCast(@alignCast(code.ptr));

    const shader_module_ci = vk.ShaderModuleCreateInfo{
        .sType = vk.STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = code.len,
        .pCode = data,
    };

    var shader_module: vk.ShaderModule = undefined;
    checkVk(vk.CreateShaderModule(self.device.handle, &shader_module_ci, vk_alloc_cbs, &shader_module)) catch |err| {
        log.err("Failed to create shader module with error: {s}", .{@errorName(err)});
        return null;
    };

    return shader_module;
}

fn createDescriptorSetLayout(self: *Self) void {
    const ubo_layout_binding = vk.DescriptorSetLayoutBinding{
        .binding = 0,
        .descriptorCount = 1,
        .descriptorType = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .stageFlags = vk.SHADER_STAGE_VERTEX_BIT,
        .pImmutableSamplers = null,
    };
    const sampler_layout_binding = vk.DescriptorSetLayoutBinding{
        .binding = 1,
        .descriptorCount = 1,
        .descriptorType = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .stageFlags = vk.SHADER_STAGE_FRAGMENT_BIT,
        .pImmutableSamplers = null,
    };

    const bindings = &[_]vk.DescriptorSetLayoutBinding{ ubo_layout_binding, sampler_layout_binding };

    const ci = vk.DescriptorSetLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = bindings.len,
        .pBindings = bindings,
    };

    checkVk(vk.CreateDescriptorSetLayout(self.device.handle, &ci, vk_alloc_cbs, &self.descriptor_set_layout)) catch @panic("failed to create descriptor set layout");
}

fn createGraphicsPipeline(self: *Self) void {
    const vertex3D_description = mesh_mod.Vertex3D.vertex_input_description;

    // const vert_shader = root.shaders.createShaderModule("triangle.vert", self.device.handle, vk_alloc_cbs) orelse @panic("failed to create vert shader module");
    const vert_shader = root.shaders.createShaderModule("uniform_buffer.vert", self.device.handle, vk_alloc_cbs) orelse @panic("failed to create vert shader module");
    defer vk.DestroyShaderModule(self.device.handle, vert_shader, vk_alloc_cbs);
    const frag_shader = root.shaders.createShaderModule("triangle.frag", self.device.handle, vk_alloc_cbs) orelse @panic("failed to create frag shader module");
    defer vk.DestroyShaderModule(self.device.handle, frag_shader, vk_alloc_cbs);

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
        .vertexBindingDescriptionCount = @as(u32, @intCast(vertex3D_description.bindings.len)),
        .pVertexBindingDescriptions = vertex3D_description.bindings.ptr,
        .vertexAttributeDescriptionCount = @as(u32, @intCast(vertex3D_description.attributes.len)),
        .pVertexAttributeDescriptions = vertex3D_description.attributes.ptr,
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
        .frontFace = vk.FRONT_FACE_COUNTER_CLOCKWISE,
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

    // const push_constant = vk.PushConstantRange{
    //     .offset = 0,
    //     .size = @sizeOf(mesh_mod.Mesh3D.PushConstants),
    //     .stageFlags = vk.SHADER_STAGE_VERTEX_BIT,
    // };

    const pipeline_layout_ci = vk.PipelineLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .setLayoutCount = 1,
        .pSetLayouts = &self.descriptor_set_layout,
        // .pushConstantRangeCount = 1,
        // .pPushConstantRanges = &push_constant,
    };

    checkVk(vk.CreatePipelineLayout(self.device.handle, &pipeline_layout_ci, null, &self.pipeline_layout)) catch
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

    checkVk(vk.CreateGraphicsPipelines(self.device.handle, null, 1, &pipeline_ci, null, &self.pipeline)) catch
        @panic("failed to create graphics pipeline");
}

/// creates command pools and buffer per frame in flight & for the singular upload context
fn createCommands(self: *Self) void {
    // Create a command pool
    const command_pool_ci = vk.CommandPoolCreateInfo{
        .sType = vk.STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = vk.COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
        .queueFamilyIndex = self.physical_device.graphics_queue_family,
    };

    for (&self.frames) |*frame| {
        checkVk(vk.CreateCommandPool(self.device.handle, &command_pool_ci, vk_alloc_cbs, &frame.command_pool)) catch log.err("Failed to create command pool", .{});
        // Allocate a command buffer from the command pool
        const command_buffer_ai = vk.CommandBufferAllocateInfo{
            .sType = vk.STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = frame.command_pool,
            .level = vk.COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };

        checkVk(vk.AllocateCommandBuffers(self.device.handle, &command_buffer_ai, &frame.main_command_buffer)) catch @panic("Failed to allocate command buffer");
    }

    // =================================
    // Upload context
    //

    // For the time being this is submitting on the graphics queue
    const upload_command_pool_ci = vk.CommandPoolCreateInfo{
        .sType = vk.STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .flags = 0,
        .queueFamilyIndex = self.physical_device.graphics_queue_family,
    };

    checkVk(vk.CreateCommandPool(self.device.handle, &upload_command_pool_ci, vk_alloc_cbs, &self.upload_context.command_pool)) catch @panic("Failed to create upload command pool");
    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(self.upload_context.command_pool, vk.DestroyCommandPool, vk_alloc_cbs),
    ) catch @panic("Out of memory");

    const upload_command_buffer_ai = vk.CommandBufferAllocateInfo{
        .sType = vk.STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .commandPool = self.upload_context.command_pool,
        .level = vk.COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1,
    };

    checkVk(vk.AllocateCommandBuffers(self.device.handle, &upload_command_buffer_ai, &self.upload_context.command_buffer)) catch @panic("Failed to allocate upload command buffer");
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
        checkVk(vk.CreateFramebuffer(self.device.handle, &ci, null, &self.swapchain_framebuffers.items[i])) catch @panic("failed to create framebuffer");
    }
}

fn createDepthResources(self: *Self) void {
    _ = self;
}

fn createTextureImage(self: *Self) void {
    const lost_empire_image = texs.loadImageFromFile(self.vma_allocator, &self.upload_context, self.device, "assets/test_img.jpg") catch @panic("Failed to load image");

    const image_view_ci = vk.ImageViewCreateInfo{
        .sType = vk.STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .viewType = vk.IMAGE_VIEW_TYPE_2D,
        .image = lost_empire_image.image,
        .format = vk.FORMAT_R8G8B8A8_SRGB,
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

    var lost_empire = texs.Texture{
        .image = lost_empire_image,
        .image_view = null,
    };

    checkVk(vk.CreateImageView(self.device.handle, &image_view_ci, vk_alloc_cbs, &lost_empire.image_view)) catch @panic("Failed to create image view");
    self.texture = lost_empire;
}

fn createTextureSampler(self: *Self) void {
    const ci = vk.SamplerCreateInfo{
        .sType = vk.STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = vk.FILTER_LINEAR,
        .minFilter = vk.FILTER_LINEAR,
        .addressModeU = vk.SAMPLER_ADDRESS_MODE_REPEAT,
        .addressModeV = vk.SAMPLER_ADDRESS_MODE_REPEAT,
        .addressModeW = vk.SAMPLER_ADDRESS_MODE_REPEAT,
        .anisotropyEnable = vk.TRUE,
        .maxAnisotropy = self.physical_device.properties.limits.maxSamplerAnisotropy,
        .borderColor = vk.BORDER_COLOR_INT_OPAQUE_BLACK,
        .unnormalizedCoordinates = vk.FALSE,
        .compareEnable = vk.FALSE,
        .compareOp = vk.COMPARE_OP_ALWAYS,
        .mipmapMode = vk.SAMPLER_MIPMAP_MODE_LINEAR,
        .mipLodBias = 0.0,
        .minLod = 0.0,
        .maxLod = 0.0,
    };

    checkVk(vk.CreateSampler(self.device.handle, &ci, null, &self.texture_sampler)) catch @panic("failed to create sampler");
}

fn createMeshes(self: *Self) void {
    const vertices_indices = [_]struct { [4]mesh_mod.Vertex3D, [6]u16 }{
        .{
            [_]mesh_mod.Vertex3D{
                .{
                    .position = Vec3.make(-0.5, -0.5, 0.0),
                    .normal = Vec3.ZERO,
                    .color = Vec3.make(1.0, 0.0, 0.0),
                    .uv = Vec2.make(1.0, 0.0),
                },
                .{
                    .position = Vec3.make(0.5, -0.5, 0.0),
                    .normal = Vec3.ZERO,
                    .color = Vec3.make(0.0, 1.0, 0.0),
                    .uv = Vec2.make(0.0, 0.0),
                },
                .{
                    .position = Vec3.make(0.5, 0.5, 0.0),
                    .normal = Vec3.ZERO,
                    .color = Vec3.make(0.0, 0.0, 1.0),
                    .uv = Vec2.make(0.0, 1.0),
                },
                .{
                    .position = Vec3.make(-0.5, 0.5, 0.0),
                    .normal = Vec3.ZERO,
                    .color = Vec3.make(1.0, 1.0, 1.0),
                    .uv = Vec2.make(1.0, 1.0),
                },
            },
            [_]u16{ 0, 1, 2, 2, 3, 0 },
        },
        .{
            [_]mesh_mod.Vertex3D{
                .{
                    .position = Vec3.make(-0.5, -0.5, -0.5),
                    .normal = Vec3.ZERO,
                    .color = Vec3.make(1.0, 0.0, 0.0),
                    .uv = Vec2.make(0.0, 0.0),
                },
                .{
                    .position = Vec3.make(0.5, -0.5, -0.5),
                    .normal = Vec3.ZERO,
                    .color = Vec3.make(0.0, 1.0, 0.0),
                    .uv = Vec2.make(1.0, 0.0),
                },
                .{
                    .position = Vec3.make(0.5, 0.5, -0.5),
                    .normal = Vec3.ZERO,
                    .color = Vec3.make(0.0, 0.0, 1.0),
                    .uv = Vec2.make(1.0, 1.0),
                },
                .{
                    .position = Vec3.make(-0.5, 0.5, -0.5),
                    .normal = Vec3.ZERO,
                    .color = Vec3.make(1.0, 1.0, 1.0),
                    .uv = Vec2.make(0.0, 1.0),
                },
            },
            [_]u16{ 0, 1, 2, 2, 3, 0 },
        },
    };

    self.meshes = self.allocator.alloc(mesh_mod.Mesh3D, vertices_indices.len) catch @panic("out of memory");
    for (vertices_indices, 0..) |vi, i| {
        var mesh = mesh_mod.Mesh3D{
            .vertices = self.allocator.dupe(mesh_mod.Vertex3D, vi.@"0"[0..]) catch @panic("out of memory"),
            .indices = self.allocator.dupe(u16, vi.@"1"[0..]) catch @panic("out of memory"),
        };

        mesh.upload(self.vma_allocator, &self.upload_context, self.device);
        self.meshes[i] = mesh;
    }
}

fn createUniformBuffers(self: *Self) void {
    const buf_size = @sizeOf(root.UniformBufferObject);
    self.uniform_buffers = self.allocator.alloc(vma_usage.AllocatedBuffer, MAX_FRAMES_IN_FLIGHT) catch @panic("out of memory");
    self.uniform_buffers_mapped = self.allocator.alloc(?*anyopaque, MAX_FRAMES_IN_FLIGHT) catch @panic("out of memory");

    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        self.uniform_buffers[i] = vma_usage.AllocatedBuffer.create(self.vma_allocator, buf_size, vk.BUFFER_USAGE_UNIFORM_BUFFER_BIT, c.vma.MEMORY_USAGE_CPU_TO_GPU);
        checkVk(c.vma.MapMemory(self.vma_allocator, self.uniform_buffers[i].allocation, &self.uniform_buffers_mapped[i])) catch @panic("failed to map uniform buffer");
    }
}

fn createDescriptorPool(self: *Self) void {
    const ubo_size = vk.DescriptorPoolSize{
        .type = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = @as(u32, @intCast(MAX_FRAMES_IN_FLIGHT)),
    };
    const sampler_size = vk.DescriptorPoolSize{
        .type = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .descriptorCount = @as(u32, @intCast(MAX_FRAMES_IN_FLIGHT)),
    };

    const sizes = &[_]vk.DescriptorPoolSize{ ubo_size, sampler_size };

    const ci = vk.DescriptorPoolCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .poolSizeCount = sizes.len,
        .pPoolSizes = sizes,
        .maxSets = @as(u32, @intCast(MAX_FRAMES_IN_FLIGHT)),
    };

    checkVk(vk.CreateDescriptorPool(self.device.handle, &ci, vk_alloc_cbs, &self.descriptor_pool)) catch @panic("failed to create descriptor pool");
}

fn createDescriptorSets(self: *Self) void {

    // i just feel like this could be better
    // basically we need to initialize layouts with copies to self.descriptor_set_layout
    const layouts = self.allocator.alloc(vk.DescriptorSetLayout, MAX_FRAMES_IN_FLIGHT) catch @panic("out of memory");
    defer self.allocator.free(layouts);
    for (0..layouts.len) |i| {
        layouts[i] = self.descriptor_set_layout;
    }

    const ai = vk.DescriptorSetAllocateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .descriptorPool = self.descriptor_pool,
        .descriptorSetCount = @as(u32, @intCast(MAX_FRAMES_IN_FLIGHT)),
        .pSetLayouts = layouts.ptr,
    };

    self.descriptor_sets = self.allocator.alloc(vk.DescriptorSet, MAX_FRAMES_IN_FLIGHT) catch @panic("out of memory");

    checkVk(vk.AllocateDescriptorSets(self.device.handle, &ai, self.descriptor_sets.ptr)) catch @panic("failed to allocate descriptor sets");

    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        const ubo_info = vk.DescriptorBufferInfo{
            .buffer = self.uniform_buffers[i].buffer,
            .offset = 0,
            .range = @sizeOf(root.UniformBufferObject),
        };

        const img_info = vk.DescriptorImageInfo{
            .imageLayout = vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .imageView = self.texture.image_view,
            .sampler = self.texture_sampler,
        };

        const ubo_write = vk.WriteDescriptorSet{
            .dstBinding = 0,
            .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = self.descriptor_sets[i],
            .dstArrayElement = 0,
            .descriptorType = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .pBufferInfo = &ubo_info,
        };

        const img_write = vk.WriteDescriptorSet{
            .dstBinding = 1,
            .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = self.descriptor_sets[i],
            .dstArrayElement = 0,
            .descriptorType = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .pImageInfo = &img_info,
        };

        const writes = &[_]vk.WriteDescriptorSet{ ubo_write, img_write };

        vk.UpdateDescriptorSets(self.device.handle, writes.len, writes, 0, null);
    }
}

fn recordCommandBuffers(self: *Self, command_buffer: vk.CommandBuffer, image_idx: u32) void {
    var begin_info = vk.CommandBufferBeginInfo{
        .sType = vk.STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
    };

    checkVk(vk.BeginCommandBuffer(command_buffer, &begin_info)) catch @panic("failed to begin command buffer");

    var render_pass_info = vk.RenderPassBeginInfo{
        .sType = vk.STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .renderPass = self.render_pass,
        .framebuffer = self.swapchain.framebuffers[image_idx],
        .renderArea = .{ .offset = .{
            .x = 0,
            .y = 0,
        }, .extent = self.swapchain.extent },
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
            .width = @floatFromInt(self.swapchain.extent.width),
            .height = @floatFromInt(self.swapchain.extent.height),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };
        vk.CmdSetViewport(command_buffer, 0, 1, &viewport);

        const scissor = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = self.swapchain.extent,
        };
        vk.CmdSetScissor(command_buffer, 0, 1, &scissor);

        vk.CmdBindDescriptorSets(
            command_buffer,
            vk.PIPELINE_BIND_POINT_GRAPHICS,
            self.pipeline_layout,
            0,
            1,
            &self.descriptor_sets[self.current_frame],
            0,
            null,
        );

        for (0..self.meshes.len) |i| {
            // const mesh_matrix = self.getMeshMatrix(i);
            // const constants = mesh_mod.Mesh3D.PushConstants{ .render_matrix = mesh_matrix };

            // //upload the matrix to the GPU via push constants
            // vk.CmdPushConstants(
            //     command_buffer,
            //     self.pipeline_layout,
            //     vk.SHADER_STAGE_VERTEX_BIT,
            //     0,
            //     @sizeOf(mesh_mod.Mesh3D.PushConstants),
            //     &constants,
            // );

            const mesh = self.meshes[i];
            const vertex_buffers = &[_]vk.Buffer{mesh.vertex_buffer.buffer};
            const offsets = &[_]u64{0};
            const first_binding: u32 = 0;
            const binding_count: u32 = @intCast(vertex_buffers.len);

            vk.CmdBindVertexBuffers(command_buffer, first_binding, binding_count, vertex_buffers, offsets);
            vk.CmdBindIndexBuffer(command_buffer, mesh.index_buffer.buffer, 0, vk.INDEX_TYPE_UINT16);
            vk.CmdDrawIndexed(command_buffer, @as(u32, @intCast(mesh.indices.len)), 1, 0, 0, 0);
        }
    }

    checkVk(vk.EndCommandBuffer(command_buffer)) catch @panic("failed to record command buffer");
}

fn createSyncObjects(self: *Self) void {

    // Frames
    for (0..MAX_FRAMES_IN_FLIGHT) |i| {
        self.frames[i].init(self.device.handle, vk_alloc_cbs);
        // checkVk(vk.CreateSemaphore(self.device.handle, &semaphore_ci, null, &self.image_available_semaphores.items[i])) catch
        //     @panic("failed to create image available semaphore");
        // checkVk(vk.CreateFence(self.device.handle, &fence_ci, null, &self.frame_fences.items[i])) catch
        //     @panic("failed to create fence");
    }

    // Upload Context
    const upload_fence_ci = vk.FenceCreateInfo{
        .sType = vk.STRUCTURE_TYPE_FENCE_CREATE_INFO,
    };

    checkVk(vk.CreateFence(self.device.handle, &upload_fence_ci, vk_alloc_cbs, &self.upload_context.upload_fence)) catch @panic("Failed to create upload fence");

    self.deletion_queue.append(
        self.allocator,
        VulkanDeleter.make(self.upload_context.upload_fence, vk.DestroyFence, vk_alloc_cbs),
    ) catch @panic("Out of memory");
}

fn drawFrame(self: *Self) void {
    const current_frame =
        self.frames[self.current_frame];

    self.updateUniformBuffer();

    const present_semaphore =
        current_frame.present_semaphore;

    checkVk(vk.WaitForFences(self.device.handle, 1, &current_frame.render_fence, vk.TRUE, std.math.maxInt(u64))) catch @panic("failed to wait for current fence");

    const swapchain_recreation_opts =
        vulkan_init.SwapchainCreateOpts{
            .physical_device = self.physical_device.handle,
            .graphics_queue_family = self.physical_device.graphics_queue_family,
            .present_queue_family = self.physical_device.present_queue_family,
            .device = self.device.handle,
            .surface = self.surface,
            .old_swapchain = self.swapchain.handle,
            .vsync = true,
            // maybe BAD! (window extent may be out of date)
            .window_width = @intCast(window_extent.width),
            .window_height = @intCast(window_extent.height),
            .alloc_cb = vk_alloc_cbs,
        };

    var image_idx: u32 = undefined;
    checkVk(vk.AcquireNextImageKHR(self.device.handle, self.swapchain.handle, std.math.maxInt(u64), present_semaphore, null, &image_idx)) catch |e|
        switch (e) {
            VkError.ErrorOutOfDateKHR => {
                self.swapchain.recreate(self.allocator, swapchain_recreation_opts, self.window, self.render_pass, vk_alloc_cbs);
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
        self.swapchain.render_semaphores[image_idx];

    checkVk(vk.ResetFences(self.device.handle, 1, &current_frame.render_fence)) catch @panic("failed to reset fences");
    checkVk(vk.ResetCommandBuffer(current_frame.main_command_buffer, 0)) catch @panic("failed to reset command buffers");
    self.recordCommandBuffers(current_frame.main_command_buffer, image_idx);

    const wait_semaphores = &[_]vk.Semaphore{present_semaphore};
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
        .pCommandBuffers = &current_frame.main_command_buffer,
    };

    checkVk(vk.QueueSubmit(self.device.graphics_queue, 1, &submit_info, current_frame.render_fence)) catch @panic("failed to submit draw command buffer");

    const present_info = vk.PresentInfoKHR{
        .sType = vk.STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = signal_semaphores,
        .swapchainCount = 1,
        .pSwapchains = &[_]vk.SwapchainKHR{self.swapchain.handle},
        .pImageIndices = &image_idx,
    };

    checkVk(vk.QueuePresentKHR(self.device.present_queue, &present_info)) catch |e| {
        if (e == VkError.ErrorOutOfDateKHR or
            e == VkError.SuboptimalKHR or
            self.framebuffer_resized)
        {
            self.framebuffer_resized = false;
            self.swapchain.recreate(self.allocator, swapchain_recreation_opts, self.window, self.render_pass, vk_alloc_cbs);
        } else {
            @panic("failed to present swapchain image");
        }
    };

    self.current_frame = (self.current_frame + 1) % @as(u32, @intCast(MAX_FRAMES_IN_FLIGHT));
    std.debug.assert(self.current_frame < @as(u32, @intCast(MAX_FRAMES_IN_FLIGHT)));
}

/// Not calling this will cause any meshes that require uniform buffer to not be drawn
/// It is more than just an update function
fn updateUniformBuffer(self: *Self) void {
    const State = struct {
        var start: i128 = 0;
    };

    // If first call, initialize start time
    if (State.start == 0) {
        State.start = std.time.nanoTimestamp();
    }

    const now = std.time.nanoTimestamp();
    const delta_ns = now - State.start;
    const time: f32 = @as(f32, (@floatFromInt(delta_ns))) / @as(f32, (@floatFromInt(std.time.ns_per_s)));

    const fov = 45.0;
    const near_plane = 0.1;
    const far_plane = 10.0;

    const aspect =
        @as(f32, @floatFromInt(self.swapchain.extent.width)) /
        @as(f32, @floatFromInt(self.swapchain.extent.height));
    var ubo = root.UniformBufferObject{
        .model = Mat4.IDENTITY.rotate(Vec3.make(0.0, 0.0, 1.0), time * 1.0),
        .view = Mat4.lookAt(Vec3.make(2.0, 2.0, 2.0), Vec3.make(0.0, 0.0, 0.0), Vec3.make(0.0, 0.0, 1.0)),
        .proj = Mat4.perspective(fov, aspect, near_plane, far_plane),
    };

    ubo.proj.j.y *= -1;

    const aligned_data: *root.UniformBufferObject = @ptrCast(@alignCast(self.uniform_buffers_mapped[self.current_frame]));
    aligned_data.* = ubo;
}
