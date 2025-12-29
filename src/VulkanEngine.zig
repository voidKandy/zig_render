const std = @import("std");
const log = std.log.scoped(.vulkan_engine);
const root = @import("root.zig");
const texs = @import("textures.zig");
const vki = @import("vulkan_init.zig");
const util = @import("vulkan_util.zig");
const frames_mod = @import("frames.zig");
const descriptor = @import("descriptor.zig");
const vma_usage = @import("vma_usage.zig");
const mesh_mod = @import("mesh.zig");
const c = @import("clibs.zig");
const PipelineBuilder = @import("PipelineBuilder.zig");
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
const Vec4 = root.math.Vec4;
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

image_deletion_queue: std.ArrayList(vma_usage.VmaImageDeleter),

global_descriptor_allocator: descriptor.Allocator = undefined,
draw_image_descriptors: vk.DescriptorSet = undefined,
draw_image_descriptor_layout: vk.DescriptorSetLayout = undefined,

draw_image: vma_usage.AllocatedImage = undefined,

swapchain: vki.Swapchain = undefined,
framebuffer_resized: bool = false,

imgui_descriptor_pool: vk.DescriptorPool = undefined,

render_pass: vk.RenderPass = undefined,
descriptor_pool: vk.DescriptorPool = undefined,

pipeline_layout: vk.PipelineLayout = undefined,
pipeline: vk.Pipeline = undefined,

compute_effect_pipeline_layout: vk.PipelineLayout = undefined,

triangle_pipeline_layout: vk.PipelineLayout = undefined,
triangle_pipeline: vk.Pipeline = undefined,

upload_context: vki.UploadContext = .{},

frames: frames_mod.FramesContainer(MAX_FRAMES_IN_FLIGHT) = .{},

/// eventually these should be string hash maps
meshes: []mesh_mod.Mesh3D = undefined,
texture: texs.Texture = undefined,

texture_sampler: vk.Sampler = undefined,

background_effects: std.ArrayList(ComputeEffect) = undefined,
current_background_effect: usize = 0,

const ComputePushConstants = struct {
    data1: Vec4 = Vec4.ZERO,
    data2: Vec4 = Vec4.ZERO,
    data3: Vec4 = Vec4.ZERO,
    data4: Vec4 = Vec4.ZERO,
};

const ComputeEffect = struct {
    name: []const u8,
    layout: vk.PipelineLayout,
    data: ComputePushConstants,
    pipeline: vk.Pipeline = undefined,
};

pub fn init(a: std.mem.Allocator) Self {
    return .{
        .allocator = a,
        .image_deletion_queue = std.ArrayList(vma_usage.VmaImageDeleter).initCapacity(a, 64) catch @panic("out of memory"),
        .background_effects = std.ArrayList(ComputeEffect).initCapacity(a, 16) catch @panic("out of memory"),
    };
}

pub fn deinit(self: *Self) void {
    checkVk(vk.DeviceWaitIdle(self.logical_device.handle)) catch @panic("Failed to wait for device idle");

    vma_usage.VmaImageDeleter.flushList(self.image_deletion_queue, self.vma_allocator, self.logical_device.handle);
    self.image_deletion_queue.deinit(self.allocator);
    self.swapchain.deinit(self.allocator, self.vma_allocator, self.logical_device.handle, vk_alloc_cbs);
    c.cimgui.impl_vulkan.Shutdown();

    self.frames.deinit(self.logical_device.handle, self.vma_allocator, vk_alloc_cbs);
    vk.DestroyDescriptorPool(self.logical_device.handle, self.imgui_descriptor_pool, vk_alloc_cbs);
    vk.DestroyDescriptorPool(self.logical_device.handle, self.descriptor_pool, vk_alloc_cbs);
    self.global_descriptor_allocator.deinit(self.logical_device.handle);
    vk.DestroyDescriptorSetLayout(self.logical_device.handle, self.draw_image_descriptor_layout, vk_alloc_cbs);

    vk.DestroyPipelineLayout(self.logical_device.handle, self.compute_effect_pipeline_layout, vk_alloc_cbs);
    for (self.background_effects.items) |*effect| {
        vk.DestroyPipeline(self.logical_device.handle, effect.pipeline, vk_alloc_cbs);
    }

    self.background_effects.deinit(self.allocator);

    vk.DestroyPipeline(self.logical_device.handle, self.triangle_pipeline, vk_alloc_cbs);
    vk.DestroyPipelineLayout(self.logical_device.handle, self.triangle_pipeline_layout, vk_alloc_cbs);
    // currently not created
    // vk.DestroyPipeline(self.logical_device.handle, self.pipeline, vk_alloc_cbs);
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
        {
            if (c.cimgui.Begin("background", &open, 0)) {
                var selected = &self.background_effects.items[self.current_background_effect];

                c.cimgui.Text("Selected effect: ", selected.name.ptr);

                _ = c.cimgui.SliderInt(
                    "Effect Index",
                    @ptrCast(&self.current_background_effect),
                    0,
                    @as(c_int, @intCast(self.background_effects.items.len)) - 1,
                );

                _ = c.cimgui.SliderFloat4("data1", &selected.data.data1.x, 0.0, 1.0);
                _ = c.cimgui.SliderFloat4("data2", &selected.data.data2.x, 0.0, 1.0);
                _ = c.cimgui.SliderFloat4("data3", &selected.data.data3.x, 0.0, 1.0);
                _ = c.cimgui.SliderFloat4("data4", &selected.data.data4.x, 0.0, 1.0);
            }
        }
        c.cimgui.End();
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
    const required_device_extensions: []const [*c]const u8 = &.{
        vk.KHR_SWAPCHAIN_EXTENSION_NAME,
        vk.KHR_SYNCHRONIZATION_2_EXTENSION_NAME,
        vk.KHR_DYNAMIC_RENDERING_EXTENSION_NAME,
        vk.KHR_DEPTH_STENCIL_RESOLVE_EXTENSION_NAME,
        vk.KHR_CREATE_RENDERPASS_2_EXTENSION_NAME,
        vk.KHR_PORTABILITY_SUBSET_EXTENSION_NAME,
    };
    const physical_device = vki.PhysicalDevice.select(self.allocator, self.instance.handle, .{
        .min_api_version = vk.MAKE_VERSION(1, 1, 0),
        // .required_extensions = required_device_extensions,
        .surface = self.surface,
        .criteria = .PreferDiscrete,
    }) catch @panic("failed to select physical device");
    self.physical_device = physical_device;

    // logical device creation
    var shader_draw_parameters_features = vk.PhysicalDeviceShaderDrawParametersFeatures{
        .sType = vk.STRUCTURE_TYPE_PHYSICAL_DEVICE_SHADER_DRAW_PARAMETERS_FEATURES,
        .shaderDrawParameters = vk.TRUE,
        .pNext = null,
    };

    const logical_device = vki.LogicalDevice.create(self.allocator, .{
        .physical_device = self.physical_device,
        .features = vk.PhysicalDeviceFeatures{
            .samplerAnisotropy = vk.TRUE,
        },
        .alloc_cb = vk_alloc_cbs,
        .pnext = &shader_draw_parameters_features,
        .device_extensions = required_device_extensions,
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
        .depth_buffer = false,
    }) catch @panic("failed to create swapchain");

    self.initDrawImage();

    self.frames.initSyncObjects(self.logical_device.handle, vk_alloc_cbs);
    self.upload_context.initSyncObjects(self.logical_device.handle, vk_alloc_cbs);
    self.frames.initCommands(self.logical_device.handle, self.physical_device, vk_alloc_cbs);
    self.upload_context.initCommands(self.logical_device.handle, self.physical_device, vk_alloc_cbs);
    // self.frames.initDescriptors(self.allocator, self.logical_device.handle, vk_alloc_cbs);
    self.frames.initDescriptorSetLayouts(self.logical_device.handle, vk_alloc_cbs);

    self.initDescriptors();

    self.createRenderPass();
    self.initPipelines();

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

fn initTrianglePipeline(self: *Self) void {
    const vert_shader = root.shaders.createShaderModule(
        "colored_triangle.vert",
        self.logical_device.handle,
        vk_alloc_cbs,
    ) orelse @panic("failed to create vert shader module");
    defer vk.DestroyShaderModule(self.logical_device.handle, vert_shader, vk_alloc_cbs);

    const frag_shader = root.shaders.createShaderModule(
        "colored_triangle.frag",
        self.logical_device.handle,
        vk_alloc_cbs,
    ) orelse @panic("failed to create frag shader module");
    defer vk.DestroyShaderModule(self.logical_device.handle, frag_shader, vk_alloc_cbs);

    const ci = vki.pipelineLayoutCreateInfo();
    checkVk(vk.CreatePipelineLayout(self.logical_device.handle, &ci, vk_alloc_cbs, &self.triangle_pipeline_layout)) catch
        @panic("failed to create triangle pipeline layout");

    var builder = PipelineBuilder.init(self.allocator, vk_alloc_cbs);
    defer builder.deinit();

    builder.layout = self.triangle_pipeline_layout;
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
        .width = @as(f32, @floatFromInt(self.swapchain.extent.width)),
        .height = @as(f32, @floatFromInt(self.swapchain.extent.height)),
        .minDepth = 0.0,
        .maxDepth = 1.0,
    };

    builder.scissor = .{
        .offset = .{ .x = 0, .y = 0 },
        .extent = self.swapchain.extent,
    };

    builder.setPolygonMode(vk.POLYGON_MODE_FILL);
    builder.setCullMode(vk.CULL_MODE_NONE, vk.FRONT_FACE_CLOCKWISE);
    builder.setMultisamplingNone();
    builder.color_blend_attachment = vki.defaultColorBlendAttachmentState();
    builder.disableBlending();

    // builder.setColorAttachmentFormat(self.draw_image.format);
    // builder.setDepthFormat(vk.FORMAT_UNDEFINED);

    self.triangle_pipeline = builder.build(self.logical_device.handle, self.render_pass);
}
fn initPipelines(self: *Self) void {
    // self.initGraphicsPipeline();
    self.initTrianglePipeline();
    self.initBackgroundPipelines();
}

fn initDrawImage(self: *Self) void {

    //hardcoding the draw format to 32 bit float
    self.draw_image.format = vk.FORMAT_R16G16B16A16_SFLOAT;
    self.draw_image.extent =
        vk.Extent3D{ .width = window_extent.width, .height = window_extent.height, .depth = 1 };

    const usages: vk.ImageUsageFlags =
        vk.IMAGE_USAGE_TRANSFER_SRC_BIT |
        vk.IMAGE_USAGE_TRANSFER_DST_BIT |
        vk.IMAGE_USAGE_STORAGE_BIT | vk.IMAGE_USAGE_COLOR_ATTACHMENT_BIT;

    const ci = vki.imageCreateInfo(self.draw_image.format, usages, self.draw_image.extent);

    //for the draw image, we want to allocate it from gpu local memory
    const ai = c.vma.AllocationCreateInfo{
        .usage = c.vma.MEMORY_USAGE_GPU_ONLY,
        .requiredFlags = vk.MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
    };

    checkVk(c.vma.CreateImage(self.vma_allocator, &ci, &ai, &self.draw_image.image, &self.draw_image.allocation, null)) catch
        @panic("failed to create draw image");
    //allocate and create the image

    //build a image-view for the draw image to use for rendering
    const render_view_info = vki.imageViewCreateInfo(self.draw_image.format, self.draw_image.image, vk.IMAGE_ASPECT_COLOR_BIT);

    checkVk(vk.CreateImageView(self.logical_device.handle, &render_view_info, vk_alloc_cbs, &self.draw_image.view)) catch @panic("failed to create image view");

    self.image_deletion_queue.append(self.allocator, vma_usage.VmaImageDeleter{
        .callbacks = vk_alloc_cbs,
        .image = self.draw_image,
    }) catch @panic("out of memory");
}

fn initDescriptors(self: *Self) void {
    // maybe should be initted elsewhere?
    self.global_descriptor_allocator = descriptor.Allocator.init(self.allocator, vk_alloc_cbs);
    //create a descriptor pool that will hold 10 sets with 1 image each

    const sizes = [_]descriptor.PoolSizeRatio{.{ .typ = vk.DESCRIPTOR_TYPE_STORAGE_IMAGE, .ratio = 1.0 }};
    self.global_descriptor_allocator.initPool(self.logical_device.handle, 10, &sizes);
    {
        var builder = descriptor.LayoutBuilder.init(self.allocator);
        defer builder.deinit(self.allocator);
        builder.addBinding(self.allocator, 0, vk.DESCRIPTOR_TYPE_STORAGE_IMAGE);
        self.draw_image_descriptor_layout = builder.build(self.logical_device.handle, vk.SHADER_STAGE_COMPUTE_BIT, null, 0, vk_alloc_cbs);
    }

    self.draw_image_descriptors = self.global_descriptor_allocator.allocate(self.logical_device.handle, self.draw_image_descriptor_layout);

    const draw_img_info = vk.DescriptorImageInfo{
        .imageLayout = vk.IMAGE_LAYOUT_GENERAL,
        .imageView = self.draw_image.view,
    };

    const draw_img_write = vk.WriteDescriptorSet{
        .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .pNext = null,

        .dstBinding = 0,
        .dstSet = self.draw_image_descriptors,
        .descriptorCount = 1,
        .descriptorType = vk.DESCRIPTOR_TYPE_STORAGE_IMAGE,
        .pImageInfo = &draw_img_info,
    };

    vk.UpdateDescriptorSets(self.logical_device.handle, 1, &draw_img_write, 0, null);
}

fn initBackgroundPipelines(self: *Self) void {
    const push_constant = vk.PushConstantRange{
        .offset = 0,
        .size = @sizeOf(ComputePushConstants),
        .stageFlags = vk.SHADER_STAGE_COMPUTE_BIT,
    };

    const compute_layout = vk.PipelineLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pNext = null,
        .pSetLayouts = &self.draw_image_descriptor_layout,
        .setLayoutCount = 1,
        .pPushConstantRanges = &push_constant,
        .pushConstantRangeCount = 1,
    };

    checkVk(vk.CreatePipelineLayout(self.logical_device.handle, &compute_layout, vk_alloc_cbs, &self.compute_effect_pipeline_layout)) catch
        @panic("failed to create compute pipeline layout");

    const gradient_shader = root.shaders.createShaderModule("gradient_color.comp", self.logical_device.handle, vk_alloc_cbs) orelse @panic("failed to create compute shader module");
    defer vk.DestroyShaderModule(self.logical_device.handle, gradient_shader, vk_alloc_cbs);
    const sky_shader = root.shaders.createShaderModule("sky.comp", self.logical_device.handle, vk_alloc_cbs) orelse @panic("failed to create compute shader module");
    defer vk.DestroyShaderModule(self.logical_device.handle, sky_shader, vk_alloc_cbs);

    const stage_info = vk.PipelineShaderStageCreateInfo{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .pNext = null,
        .stage = vk.SHADER_STAGE_COMPUTE_BIT,
        .module = gradient_shader,
        .pName = "main",
    };

    var ci =
        vk.ComputePipelineCreateInfo{
            .sType = vk.STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO,
            .pNext = null,
            .layout = self.compute_effect_pipeline_layout,
            .stage = stage_info,
        };

    var gradient = ComputeEffect{
        .layout = self.compute_effect_pipeline_layout,
        .name = "gradient",
        .data = .{
            .data1 = Vec4.make(1.0, 0.0, 0.0, 1.0),
            .data2 = Vec4.make(0.0, 0.0, 1.0, 1.0),
        },
    };

    checkVk(vk.CreateComputePipelines(self.logical_device.handle, null, 1, &ci, vk_alloc_cbs, &gradient.pipeline)) catch @panic("failed to create compute pipeline");

    //change the shader module only to create the sky shader
    ci.stage.module = sky_shader;

    var sky = ComputeEffect{
        .layout = self.compute_effect_pipeline_layout,
        .name = "sky",
        .data = .{
            .data1 = Vec4.make(0.1, 0.2, 0.4, 0.97),
        },
    };
    checkVk(vk.CreateComputePipelines(self.logical_device.handle, null, 1, &ci, vk_alloc_cbs, &sky.pipeline)) catch @panic("failed to create compute pipeline");

    self.background_effects.append(self.allocator, gradient) catch @panic("out of memory");
    self.background_effects.append(self.allocator, sky) catch @panic("out of memory");
}

fn createRenderPass(self: *Self) void {
    const color_attachment = vk.AttachmentDescription{
        .format = self.draw_image.format,
        .samples = vk.SAMPLE_COUNT_1_BIT,
        .loadOp = vk.ATTACHMENT_LOAD_OP_LOAD,
        .storeOp = vk.ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = vk.ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        .finalLayout = vk.IMAGE_LAYOUT_PRESENT_SRC_KHR,
    };

    const color_attachment_ref = vk.AttachmentReference{
        .attachment = 0,
        .layout = vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };

    // const depth_attachment = vk.AttachmentDescription{
    //     .format = vki.DepthResource.findDepthFormat(self.physical_device),
    //     .samples = vk.SAMPLE_COUNT_1_BIT,
    //     .loadOp = vk.ATTACHMENT_LOAD_OP_LOAD,
    //     .storeOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
    //     .stencilLoadOp = vk.ATTACHMENT_LOAD_OP_DONT_CARE,
    //     .stencilStoreOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
    //     .initialLayout = vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    //     .finalLayout = vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    // };

    // const depth_attachment_ref = vk.AttachmentReference{
    //     .attachment = 1,
    //     .layout = vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    // };

    const subpass = vk.SubpassDescription{
        .pipelineBindPoint = vk.PIPELINE_BIND_POINT_GRAPHICS,
        .colorAttachmentCount = 1,
        .pColorAttachments = &color_attachment_ref,
        .pDepthStencilAttachment = null,
        // .pDepthStencilAttachment = &depth_attachment_ref,
    };

    const dependency = vk.SubpassDependency{
        .srcSubpass = vk.SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | vk.PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
        .srcAccessMask = vk.ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        // .srcAccessMask = vk.ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
        .dstStageMask = vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | vk.PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
        .dstAccessMask = vk.ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        // | vk.ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
    };

    const all_attachments = &[_]vk.AttachmentDescription{
        color_attachment,
        // depth_attachment
    };

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

fn initGraphicsPipeline(self: *Self) void {
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

    // const depth_stencil = vk.PipelineDepthStencilStateCreateInfo{
    //     .sType = vk.STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
    //     .depthTestEnable = vk.TRUE,
    //     .depthWriteEnable = vk.TRUE,
    //     .depthCompareOp = vk.COMPARE_OP_LESS,
    //     .depthBoundsTestEnable = vk.FALSE,
    //     .minDepthBounds = 0.0,
    //     .maxDepthBounds = 1.0,
    //     .front = .{},
    //     .back = .{},
    // };

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
        // .pDepthStencilState = &depth_stencil,
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
        .image = .{
            .allocation = test_img.allocation,
            .image = test_img.image,
        },
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

// this function is like a meta staging zone for meshes
fn createMeshes(self: *Self) void {
    const vertices_indices = [_]struct { []const mesh_mod.Vertex3D, []const u16 }{
        .{
            &[_]mesh_mod.Vertex3D{
                .{
                    .position = Vec3.make(-1.0, 1.0, 0.0),
                    .normal = Vec3.ZERO,
                    .color = Vec3.make(1.0, 0.0, 0.0),
                    .uv = Vec2.make(1.0, 0.0),
                },
                .{
                    .position = Vec3.make(1.0, 1.0, 0.0),
                    .normal = Vec3.ZERO,
                    .color = Vec3.make(0.0, 0.0, 1.0),
                    .uv = Vec2.make(0.0, 1.0),
                },
                .{
                    .position = Vec3.make(0.0, -1.0, 0.0),
                    .normal = Vec3.ZERO,
                    .color = Vec3.make(1.0, 1.0, 1.0),
                    .uv = Vec2.make(1.0, 1.0),
                },
            },
            &[_]u16{ 0, 1, 2 },
        },
        .{
            &[_]mesh_mod.Vertex3D{
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
            &[_]u16{ 0, 1, 2, 2, 3, 0 },
        },
        .{
            &[_]mesh_mod.Vertex3D{
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
            &[_]u16{ 0, 1, 2, 2, 3, 0 },
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

fn recordCommandBuffer(self: *Self, command_buffer: vk.CommandBuffer, image_idx: u32) void {
    var begin_info = vk.CommandBufferBeginInfo{
        .sType = vk.STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
    };

    checkVk(vk.BeginCommandBuffer(command_buffer, &begin_info)) catch @panic("failed to begin command buffer");
    defer checkVk(vk.EndCommandBuffer(command_buffer)) catch @panic("failed to record command buffer");

    util.transitionImageLayout(
        command_buffer,
        self.draw_image.image,
        vk.IMAGE_LAYOUT_UNDEFINED,
        vk.IMAGE_LAYOUT_GENERAL,
        vk.ACCESS_MEMORY_WRITE_BIT,
        vk.ACCESS_MEMORY_READ_BIT | vk.ACCESS_MEMORY_WRITE_BIT,
    );

    self.drawBackground(command_buffer);

    util.transitionImageLayout(
        command_buffer,
        self.draw_image.image,
        vk.IMAGE_LAYOUT_GENERAL,
        vk.IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        vk.ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        vk.ACCESS_TRANSFER_WRITE_BIT | vk.ACCESS_TRANSFER_READ_BIT,
    );

    util.transitionImageLayout(
        command_buffer,
        self.swapchain.images[image_idx],
        vk.IMAGE_LAYOUT_UNDEFINED,
        vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        vk.ACCESS_TRANSFER_READ_BIT,
        vk.ACCESS_MEMORY_READ_BIT,
    );

    util.copyImageToImage(
        command_buffer,
        self.draw_image.image,
        self.swapchain.images[image_idx],
        vk.Extent2D{
            .height = self.draw_image.extent.height,
            .width = self.draw_image.extent.width,
        },
        self.swapchain.extent,
    );

    util.transitionImageLayout(
        command_buffer,
        self.swapchain.images[image_idx],
        vk.IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
        vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        vk.ACCESS_MEMORY_WRITE_BIT,
        vk.ACCESS_MEMORY_READ_BIT | vk.ACCESS_MEMORY_WRITE_BIT,
    );
    {
        var render_pass_info = vk.RenderPassBeginInfo{
            .sType = vk.STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .renderPass = self.render_pass,
            .framebuffer = self.swapchain.framebuffers[image_idx],
            .renderArea = .{ .offset = .{
                .x = 0,
                .y = 0,
            }, .extent = vk.Extent2D{
                .height = self.swapchain.extent.height,
                .width = self.swapchain.extent.width,
            } },
        };

        vk.CmdBeginRenderPass(command_buffer, &render_pass_info, vk.SUBPASS_CONTENTS_INLINE);
        defer vk.CmdEndRenderPass(command_buffer);

        self.drawGeometry(command_buffer);
        c.cimgui.impl_vulkan.RenderDrawData(c.cimgui.GetDrawData(), command_buffer);
    }
}

fn drawGeometry(self: *Self, cmd: vk.CommandBuffer) void {
    vk.CmdBindPipeline(cmd, vk.PIPELINE_BIND_POINT_GRAPHICS, self.triangle_pipeline);
    const viewport = vk.Viewport{
        .x = 0,
        .y = 0,
        .width = @as(f32, (@floatFromInt(self.swapchain.extent.width))),
        .height = @as(f32, (@floatFromInt(self.swapchain.extent.height))),
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
            .width = self.swapchain.extent.width,
            .height = self.swapchain.extent.height,
        },
    };
    // BAD
    const mesh = self.meshes[0];

    const offset: u64 = 0;
    vk.CmdBindVertexBuffers(cmd, 0, 1, &mesh.vertex_buffer.buffer, &offset);

    vk.CmdSetScissor(cmd, 0, 1, &scissor);

    // vk.CmdDrawIndexed(cmd, @as(u32, @intCast(mesh.indices.len), 1, mesh, vertexOffset: i32, firstInstance: u32)
    vk.CmdDraw(cmd, @as(u32, @intCast(mesh.vertices.len)), 1, 0, 0);
}

fn drawBackground(self: *Self, cmd: vk.CommandBuffer) void {
    const effect = self.background_effects.items[self.current_background_effect];
    vk.CmdBindPipeline(cmd, vk.PIPELINE_BIND_POINT_COMPUTE, effect.pipeline);

    vk.CmdBindDescriptorSets(
        cmd,
        vk.PIPELINE_BIND_POINT_COMPUTE,
        effect.layout,
        0,
        1,
        &self.draw_image_descriptors,
        0,
        null,
    );

    vk.CmdPushConstants(cmd, self.compute_effect_pipeline_layout, vk.SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(ComputePushConstants), &effect.data);

    // execute the compute pipeline dispatch. We are using 16x16 workgroup size so we need to divide by it
    const w: u32 = @intFromFloat(std.math.ceil(@as(f32, @floatFromInt(self.draw_image.extent.width)) / 16.0));
    const h: u32 = @intFromFloat(std.math.ceil(@as(f32, @floatFromInt(self.draw_image.extent.height)) / 16.0));
    vk.CmdDispatch(cmd, w, h, 1);
}

fn drawFrame(self: *Self) void {
    var current_frame = self.frames.currentFrame();

    // self.updateUniformBuffer();

    const present_semaphore =
        current_frame.render_semaphore;

    checkVk(vk.WaitForFences(self.logical_device.handle, 1, &current_frame.render_fence, vk.TRUE, std.math.maxInt(u64))) catch @panic("failed to wait for current fence");
    // current_frame.reset(self.logical_device.handle);

    var image_idx: u32 = undefined;
    checkVk(vk.AcquireNextImageKHR(self.logical_device.handle, self.swapchain.handle, std.math.maxInt(u64), present_semaphore, null, &image_idx)) catch |e|
        switch (e) {
            VkError.ErrorOutOfDateKHR => {
                self.framebuffer_resized = true;
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
    self.recordCommandBuffer(current_frame.main_command_buffer, image_idx);

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
                vki.SwapchainCreateOpts{
                    .physical_device = self.physical_device,
                    .logical_device = self.logical_device.handle,
                    .surface = self.surface,
                    .old_swapchain = self.swapchain.handle,
                    .vsync = true,
                    .window_width = @intCast(window_extent.width),
                    .window_height = @intCast(window_extent.height),
                    .alloc_cb = vk_alloc_cbs,
                    .depth_buffer = false,
                },
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
