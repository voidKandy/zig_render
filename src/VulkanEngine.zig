const std = @import("std");
const log = std.log.scoped(.vulkan_engine);
const root = @import("root.zig");
const texs = @import("textures.zig");
const vki = @import("vulkan_init.zig");
const frames_mod = @import("frames.zig");
const vma_usage = @import("vma_usage.zig");
const mesh_mod = @import("mesh.zig");
const c = @import("clibs.zig");
const vk = c.vk;
const checkVk = vki.checkVk;
const sdl = c.sdl;
const checkSdl = root.checkSdl;
const VkError = vki.VkError;
const UploadContext = vki.UploadContext;
const FrameData = frames_mod.FrameData;
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
surface: vk.SurfaceKHR = undefined,
instance: vki.Instance = undefined,

physical_device: vki.PhysicalDevice = undefined,
logical_device: vki.LogicalDevice = undefined,

swapchain: vki.Swapchain = undefined,
framebuffer_resized: bool = false,

imgui_descriptor_pool: vk.DescriptorPool = undefined,

render_pass: vk.RenderPass = undefined,
descriptor_pool: vk.DescriptorPool = undefined,

pipeline_layout: vk.PipelineLayout = undefined,
pipeline: vk.Pipeline = undefined,

upload_context: vki.UploadContext = .{},

frames: frames_mod.FramesContainer(MAX_FRAMES_IN_FLIGHT) = .{},

/// eventually these should be string hash maps
meshes: []mesh_mod.Mesh3D = undefined,
texture: texs.Texture = undefined,

texture_sampler: vk.Sampler = undefined,

pub fn init(a: std.mem.Allocator) Self {
    return .{
        .allocator = a,
    };
}

pub fn deinit(self: *Self) void {
    checkVk(vk.DeviceWaitIdle(self.logical_device.handle)) catch @panic("Failed to wait for device idle");
    self.swapchain.deinit(self.allocator, self.vma_allocator, self.logical_device.handle, vk_alloc_cbs);
    c.cimgui.impl_vulkan.Shutdown();

    self.frames.deinit(self.logical_device.handle, self.vma_allocator, vk_alloc_cbs);
    vk.DestroyDescriptorPool(self.logical_device.handle, self.imgui_descriptor_pool, vk_alloc_cbs);
    vk.DestroyDescriptorPool(self.logical_device.handle, self.descriptor_pool, vk_alloc_cbs);
    vk.DestroyPipeline(self.logical_device.handle, self.pipeline, vk_alloc_cbs);
    vk.DestroyPipelineLayout(self.logical_device.handle, self.pipeline_layout, vk_alloc_cbs);

    vk.DestroyRenderPass(self.logical_device.handle, self.render_pass, vk_alloc_cbs);

    self.upload_context.deinit(self.logical_device.handle, vk_alloc_cbs);
    vk.DestroySampler(self.logical_device.handle, self.texture_sampler, vk_alloc_cbs);

    // texture should have deinit?
    vk.DestroyImageView(self.logical_device.handle, self.texture.image_view, vk_alloc_cbs);
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
    vk.DestroyDevice(self.logical_device.handle, vk_alloc_cbs);

    if (self.instance.debug_messenger != null) {
        const destroy_fn = self.instance.getDestroyDebugUtilsMessengerFn() orelse @panic("Debug messenger present but there is no destroy function?")();
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
            _ = c.cimgui.impl_sdl3.ProcessEvent(&event);
        }

        var open = true;
        // Imgui frame
        c.cimgui.impl_vulkan.NewFrame();
        c.cimgui.impl_sdl3.NewFrame();
        c.cimgui.NewFrame();
        c.cimgui.ShowDemoWindow(&open);
        c.cimgui.Render();

        self.drawFrame();
    }

    _ = vk.DeviceWaitIdle(self.logical_device.handle);
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

    self.instance = vki.Instance.create(std.heap.page_allocator, .{
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
    const physical_device = vki.PhysicalDevice.select(self.allocator, self.instance.handle, .{
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
    const logical_device = vki.LogicalDevice.create(self.allocator, .{
        .physical_device = self.physical_device,
        .features = vk.PhysicalDeviceFeatures{
            .samplerAnisotropy = vk.TRUE,
        },
        .alloc_cb = vk_alloc_cbs,
        .pnext = &shader_draw_parameters_features,
    }) catch @panic("Failed to create logical device");
    self.logical_device = logical_device;

    // vma allocator
    const allocator_ci = c.vma.AllocatorCreateInfo{
        .physicalDevice = self.physical_device.handle,
        .device = self.logical_device.handle,
        .instance = self.instance.handle,
    };
    checkVk(c.vma.CreateAllocator(&allocator_ci, &self.vma_allocator)) catch @panic("Failed to create VMA allocator");

    // Swapchain creation
    var win_width: c_int, var win_height: c_int = .{ undefined, undefined };
    checkSdl(c.sdl.GetWindowSize(self.window, &win_width, &win_height));

    self.swapchain = vki.Swapchain.create(self.allocator, self.vma_allocator, .{
        .physical_device = self.physical_device,
        .logical_device = self.logical_device.handle,
        .surface = self.surface,
        .old_swapchain = null,
        .vsync = true,
        .window_width = @intCast(win_width),
        .window_height = @intCast(win_height),
        .alloc_cb = vk_alloc_cbs,
        .depth_buffer = true,
    }) catch @panic("failed to create swapchain");

    self.frames.initSyncObjects(self.logical_device.handle, vk_alloc_cbs);
    self.upload_context.initSyncObjects(self.logical_device.handle, vk_alloc_cbs);
    self.frames.initCommands(self.logical_device.handle, self.physical_device, vk_alloc_cbs);
    self.upload_context.initCommands(self.logical_device.handle, self.physical_device, vk_alloc_cbs);
    self.frames.initDescriptorSetLayouts(self.logical_device.handle, vk_alloc_cbs);

    self.createRenderPass();
    self.createGraphicsPipeline();

    self.swapchain.createFramebuffers(
        self.allocator,
        self.logical_device.handle,
        self.render_pass,
        vk_alloc_cbs,
    ) catch @panic("failed to create framebuffers");

    self.createTextureImage();
    self.createTextureSampler();
    self.createMeshes();
    self.createDescriptorPool();
    self.frames.initBuffers(self.vma_allocator);
    self.frames.allocateDescriptorSets(self.logical_device.handle, self.descriptor_pool);
    self.frames.updateDescriptorSets(self.logical_device.handle, self.texture.image_view, self.texture_sampler);
    self.initImgui();
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

    const depth_attachment = vk.AttachmentDescription{
        .format = vki.DepthResource.findDepthFormat(self.physical_device),
        .samples = vk.SAMPLE_COUNT_1_BIT,
        .loadOp = vk.ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
        .stencilLoadOp = vk.ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = vk.IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    };

    const depth_attachment_ref = vk.AttachmentReference{
        .attachment = 1,
        .layout = vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    };

    const subpass = vk.SubpassDescription{
        .pipelineBindPoint = vk.PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_attachment_ref,
        .pDepthStencilAttachment = &depth_attachment_ref,
    };

    const dependency = vk.SubpassDependency{
        .srcSubpass = vk.SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | vk.PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
        .srcAccessMask = vk.ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
        .dstStageMask = vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | vk.PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
        .dstAccessMask = vk.ACCESS_COLOR_ATTACHMENT_WRITE_BIT | vk.ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
    };

    const all_attachments = &[_]vk.AttachmentDescription{ color_attachment, depth_attachment };

    const ci = vk.RenderPassCreateInfo{
        .sType = vk.STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .attachmentCount = all_attachments.len,
        .pAttachments = all_attachments,
        .subpassCount = 1,
        .pSubpasses = &subpass,
        .dependencyCount = 1,
        .pDependencies = &dependency,
    };

    checkVk(vk.CreateRenderPass(self.logical_device.handle, &ci, vk_alloc_cbs, &self.render_pass)) catch @panic("failed to create render pass");
}

fn createGraphicsPipeline(self: *Self) void {
    const vertex3D_description = mesh_mod.Vertex3D.vertex_input_description;

    // const vert_shader = root.shaders.createShaderModule("triangle.vert", self.device.handle, vk_alloc_cbs) orelse @panic("failed to create vert shader module");
    const vert_shader = root.shaders.createShaderModule("uniform_buffer.vert", self.logical_device.handle, vk_alloc_cbs) orelse @panic("failed to create vert shader module");
    defer vk.DestroyShaderModule(self.logical_device.handle, vert_shader, vk_alloc_cbs);
    const frag_shader = root.shaders.createShaderModule("triangle.frag", self.logical_device.handle, vk_alloc_cbs) orelse @panic("failed to create frag shader module");
    defer vk.DestroyShaderModule(self.logical_device.handle, frag_shader, vk_alloc_cbs);

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
        .pSetLayouts = &self.frames.global_descriptor_set_layout,
        // .pushConstantRangeCount = 1,
        // .pPushConstantRanges = &push_constant,
    };

    checkVk(vk.CreatePipelineLayout(self.logical_device.handle, &pipeline_layout_ci, null, &self.pipeline_layout)) catch
        @panic("failed to create pipeline layout");

    const depth_stencil = vk.PipelineDepthStencilStateCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        .depthTestEnable = vk.TRUE,
        .depthWriteEnable = vk.TRUE,
        .depthCompareOp = vk.COMPARE_OP_LESS,
        .depthBoundsTestEnable = vk.FALSE,
        .minDepthBounds = 0.0,
        .maxDepthBounds = 1.0,
        .front = .{},
        .back = .{},
    };

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
        .pDepthStencilState = &depth_stencil,
        .pDynamicState = &dynamic_state,
        .layout = self.pipeline_layout,
        .renderPass = self.render_pass,
        .subpass = 0,
        .basePipelineHandle = null,
    };

    checkVk(vk.CreateGraphicsPipelines(self.logical_device.handle, null, 1, &pipeline_ci, null, &self.pipeline)) catch
        @panic("failed to create graphics pipeline");
}

fn createTextureImage(self: *Self) void {
    const test_img = texs.loadImageFromFile(self.vma_allocator, &self.upload_context, self.logical_device, "assets/test_img.jpg") catch @panic("Failed to load image");

    const image_view_ci = vk.ImageViewCreateInfo{
        .sType = vk.STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .viewType = vk.IMAGE_VIEW_TYPE_2D,
        .image = test_img.image,
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
        .image = test_img,
        .image_view = null,
    };

    checkVk(vk.CreateImageView(self.logical_device.handle, &image_view_ci, vk_alloc_cbs, &lost_empire.image_view)) catch @panic("Failed to create image view");
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

    checkVk(vk.CreateSampler(self.logical_device.handle, &ci, null, &self.texture_sampler)) catch @panic("failed to create sampler");
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

        mesh.upload(self.vma_allocator, &self.upload_context, self.logical_device);
        self.meshes[i] = mesh;
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

    checkVk(vk.CreateDescriptorPool(self.logical_device.handle, &ci, vk_alloc_cbs, &self.descriptor_pool)) catch @panic("failed to create descriptor pool");
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

    // should be defined in the same order that attachments are defined in createRenderPass
    const clear_values = &[_]vk.ClearValue{
        .{
            .color = .{
                .float32 = .{0} ** 4,
            },
        },
        .{
            .depthStencil = .{ .depth = 1.0, .stencil = 0.0 },
        },
    };

    render_pass_info.clearValueCount = @as(u32, @intCast(clear_values.len));
    render_pass_info.pClearValues = clear_values;

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
            &self.frames.currentFrame().global.descriptor_set,
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

        c.cimgui.impl_vulkan.RenderDrawData(c.cimgui.GetDrawData(), command_buffer);
    }

    checkVk(vk.EndCommandBuffer(command_buffer)) catch @panic("failed to record command buffer");
}

fn drawFrame(self: *Self) void {
    const current_frame = self.frames.currentFrame();

    self.updateUniformBuffer();

    const present_semaphore =
        current_frame.present_semaphore;

    checkVk(vk.WaitForFences(self.logical_device.handle, 1, &current_frame.render_fence, vk.TRUE, std.math.maxInt(u64))) catch @panic("failed to wait for current fence");

    const swapchain_recreation_opts =
        vki.SwapchainCreateOpts{
            .physical_device = self.physical_device,
            .logical_device = self.logical_device.handle,
            .surface = self.surface,
            .old_swapchain = self.swapchain.handle,
            .vsync = true,
            // maybe BAD! (window extent may be out of date)
            .window_width = @intCast(window_extent.width),
            .window_height = @intCast(window_extent.height),
            .alloc_cb = vk_alloc_cbs,
            .depth_buffer = true,
        };

    var image_idx: u32 = undefined;
    checkVk(vk.AcquireNextImageKHR(self.logical_device.handle, self.swapchain.handle, std.math.maxInt(u64), present_semaphore, null, &image_idx)) catch |e|
        switch (e) {
            VkError.ErrorOutOfDateKHR => {
                self.swapchain.recreate(
                    self.allocator,
                    self.vma_allocator,
                    swapchain_recreation_opts,
                    self.window,
                    self.render_pass,
                    vk_alloc_cbs,
                );
                self.framebuffer_resized = false;
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

    checkVk(vk.ResetFences(self.logical_device.handle, 1, &current_frame.render_fence)) catch @panic("failed to reset fences");
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

    checkVk(vk.QueueSubmit(self.logical_device.graphics_queue, 1, &submit_info, current_frame.render_fence)) catch @panic("failed to submit draw command buffer");

    const present_info = vk.PresentInfoKHR{
        .sType = vk.STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = signal_semaphores,
        .swapchainCount = 1,
        .pSwapchains = &[_]vk.SwapchainKHR{self.swapchain.handle},
        .pImageIndices = &image_idx,
    };

    checkVk(vk.QueuePresentKHR(self.logical_device.present_queue, &present_info)) catch |e| {
        if (e == VkError.ErrorOutOfDateKHR or
            e == VkError.SuboptimalKHR or
            self.framebuffer_resized)
        {
            self.swapchain.recreate(
                self.allocator,
                self.vma_allocator,
                swapchain_recreation_opts,
                self.window,
                self.render_pass,
                vk_alloc_cbs,
            );
            self.framebuffer_resized = false;
        } else {
            @panic("failed to present swapchain image");
        }
    };

    self.frames.incrementFrame();
}

/// If this function isn't called no uniform buffer will be passed to the shader, causing nothing to be drawn
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
    var ubo = frames_mod.GPUCameraData{
        .model = Mat4.IDENTITY.rotate(Vec3.make(0.0, 0.0, 1.0), time * 1.0),
        .view = Mat4.lookAt(Vec3.make(2.0, 2.0, 2.0), Vec3.make(0.0, 0.0, 0.0), Vec3.make(0.0, 0.0, 1.0)),
        .proj = Mat4.perspective(fov, aspect, near_plane, far_plane),
    };

    ubo.proj.j.y *= -1;

    const aligned_data: *frames_mod.GPUCameraData = @ptrCast(@alignCast(self.frames.currentFrame().global.mapped));
    aligned_data.* = ubo;
}

fn initImgui(self: *Self) void {
    const pool_sizes = [_]vk.DescriptorPoolSize{
        .{
            .type = vk.DESCRIPTOR_TYPE_SAMPLER,
            .descriptorCount = 1000,
        },
        .{
            .type = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1000,
        },
        .{
            .type = vk.DESCRIPTOR_TYPE_SAMPLED_IMAGE,
            .descriptorCount = 1000,
        },
        .{
            .type = vk.DESCRIPTOR_TYPE_STORAGE_IMAGE,
            .descriptorCount = 1000,
        },
        .{
            .type = vk.DESCRIPTOR_TYPE_UNIFORM_TEXEL_BUFFER,
            .descriptorCount = 1000,
        },
        .{
            .type = vk.DESCRIPTOR_TYPE_STORAGE_TEXEL_BUFFER,
            .descriptorCount = 1000,
        },
        .{
            .type = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1000,
        },
        .{
            .type = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
            .descriptorCount = 1000,
        },
        .{
            .type = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC,
            .descriptorCount = 1000,
        },
        .{
            .type = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC,
            .descriptorCount = 1000,
        },
        .{
            .type = vk.DESCRIPTOR_TYPE_INPUT_ATTACHMENT,
            .descriptorCount = 1000,
        },
    };

    const pool_ci = vk.DescriptorPoolCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .flags = vk.DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT,
        .maxSets = 1000,
        .poolSizeCount = @as(u32, @intCast(pool_sizes.len)),
        .pPoolSizes = &pool_sizes[0],
    };

    checkVk(vk.CreateDescriptorPool(self.logical_device.handle, &pool_ci, vk_alloc_cbs, &self.imgui_descriptor_pool)) catch @panic("Failed to create imgui descriptor pool");

    _ = c.cimgui.CreateContext(null);
    _ = c.cimgui.impl_sdl3.InitForVulkan(self.window);

    var init_info = c.cimgui.impl_vulkan.InitInfo{
        .Instance = self.instance.handle,
        .PhysicalDevice = self.physical_device.handle,
        .Device = self.logical_device.handle,
        .QueueFamily = self.physical_device.graphics_queue_family,
        .Queue = self.logical_device.graphics_queue,
        .DescriptorPool = self.imgui_descriptor_pool,
        .MinImageCount = MAX_FRAMES_IN_FLIGHT,
        .ImageCount = MAX_FRAMES_IN_FLIGHT,
        .MSAASamples = vk.SAMPLE_COUNT_1_BIT,
    };

    _ = c.cimgui.impl_vulkan.Init(&init_info, self.render_pass);
    _ = c.cimgui.impl_vulkan.CreateFontsTexture();
}
