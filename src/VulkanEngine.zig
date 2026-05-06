const std = @import("std");

const root = @import("root.zig");
const vki = root.vulkan_init;
const frames_mod = root.frames;
const descriptor = root.descriptor;
const c = root.clibs;
const BoundDescriptor = root.BoundDescriptor;
const DescriptorIndexing = root.pipelines.DescriptorIndexing;
const ResourceManager = root.ResourceManager;
const Input = root.Input;
const PipelineManager = root.pipelines.PipelineManager;
const Pipeline = root.pipelines.Pipeline;
const vma_usage = root.vma_usage;
const util = root.vulkan_util;
const vk = c.vk;
const checkVk = vki.checkVk;
const sdl = c.sdl;
const checkSdl = root.checkSdl;
const VkError = vki.VkError;
pub const MAIN_RENDER_PASS_IMAGE_FORMAT = vk.FORMAT_R16G16B16A16_SFLOAT;

const log = std.log.scoped(.VulkanEngine);
const MAX_FRAMES_IN_FLIGHT: usize = 2;
const window_extent = vk.Extent2D{ .width = 1600, .height = 900 };

const Self = @This();

pub const Allocators = struct {
    std: std.mem.Allocator,
    vma: c.vma.Allocator = undefined,
    global_descriptor: descriptor.DynamicAllocator = undefined,
};

allocs: Allocators,
alloc_cbs: ?*vk.AllocationCallbacks,

resources: ResourceManager = undefined,
createResourcesFn: *const fn (*@This()) anyerror!ResourceManager,

descriptor_sets: std.ArrayList(std.ArrayList(vk.DescriptorSet)) = undefined,

// bound_descriptors: std.StringHashMap(BoundDescriptor) = undefined,
descriptor_set: vk.DescriptorSet = undefined,
descriptor_set_layout: vk.DescriptorSetLayout = undefined,

// createBoundDescriptorsFn: *const fn (*@This()) anyerror!std.StringHashMap(BoundDescriptor),

input: Input = .{},
window: *sdl.Window = undefined,
surface: vk.SurfaceKHR = undefined,
instance: vki.Instance = undefined,

physical_device: vki.PhysicalDevice = undefined,
logical_device: vki.LogicalDevice = undefined,

/// Pipeline description for the main render pass
main_pipeline_description: DescriptorIndexing.PipelineDescription = undefined,
main_pipeline_model_description: DescriptorIndexing.ModelDesc = undefined,
main_pipeline: DescriptorIndexing = undefined,
main_render_pass: vk.RenderPass = undefined,
swapchain: vki.Swapchain = undefined,
framebuffer_resized: bool = false,
frames: frames_mod.FramesContainer(MAX_FRAMES_IN_FLIGHT) = .{},
imgui_descriptor_pool: vk.DescriptorPool = undefined,

upload_context: vki.UploadContext = .{},

pub fn init(
    a: std.mem.Allocator,
    alloc_cbs: ?*vk.AllocationCallbacks,
    // createBoundDescriptorsFn: *const fn (*@This()) anyerror!std.StringHashMap(BoundDescriptor),
    createResourcesFn: *const fn (*@This()) anyerror!ResourceManager,
) Self {
    return .{
        .alloc_cbs = alloc_cbs,
        .allocs = .{ .std = a },
        .createResourcesFn = createResourcesFn,
        // .createBoundDescriptorsFn = createBoundDescriptorsFn,
    };
}

pub fn deinit(self: *Self) void {
    checkVk(vk.DeviceWaitIdle(self.logical_device.handle)) catch @panic("Failed to wait for device idle");

    self.swapchain.deinit(self.allocs.std, self.allocs.vma, self.logical_device.handle, self.alloc_cbs);
    c.imgui.impl_vulkan.Shutdown();

    // var desc_iter = self.bound_descriptors.valueIterator();
    // while (desc_iter.next()) |desc|
    //     desc.deinit(&self.allocs);
    // self.bound_descriptors.deinit();

    self.frames.deinit(self.logical_device.handle, self.alloc_cbs);
    vk.DestroyDescriptorSetLayout(self.logical_device.handle, self.descriptor_set_layout, self.alloc_cbs);
    vk.DestroyDescriptorPool(self.logical_device.handle, self.imgui_descriptor_pool, self.alloc_cbs);
    // vk.DestroyDescriptorPool(self.logical_device.handle, self.frame_descriptor_pool, self.alloc_cbs);

    self.main_pipeline.deinit(self.logical_device.handle, self.alloc_cbs);
    self.main_pipeline_model_description.deinit(self.allocs.std);
    // for (0..self.descriptor_sets.items.len) |i| {
    //     self.descriptor_sets.items[i].deinit(self.allocs.std);
    // }
    // self.descriptor_sets.deinit(self.allocs.std);
    // self.pipeline_objects.deinit(&self.allocs, self.logical_device.handle, self.alloc_cbs);

    self.upload_context.deinit(self.logical_device.handle, self.alloc_cbs);

    self.resources.deinit(self.allocs.std, self.allocs.vma, self.logical_device.handle, self.alloc_cbs);

    vk.DestroyRenderPass(self.logical_device.handle, self.main_render_pass, self.alloc_cbs);

    self.allocs.global_descriptor.deinit(self.logical_device.handle);
    c.vma.DestroyAllocator(self.allocs.vma);
    vk.DestroyDevice(self.logical_device.handle, self.alloc_cbs);

    if (self.instance.debug_messenger != null) {
        const destroy_fn = self.instance.getDestroyDebugUtilsMessengerFn() orelse @panic("Debug messenger present but there is no destroy function?")();
        destroy_fn(self.instance.handle, self.instance.debug_messenger, self.alloc_cbs);
    }

    vk.DestroySurfaceKHR(self.instance.handle, self.surface, self.alloc_cbs);
    vk.DestroyInstance(self.instance.handle, self.alloc_cbs);

    sdl.DestroyWindow(self.window);
    sdl.Quit();
}

pub fn run(self: *Self) void {
    self.initWindow();
    self.initVulkan();

    // var quit = false;
    var event: c.sdl.Event = undefined;

    while (!self.input.quit) {
        self.input = .{};
        while (c.sdl.PollEvent(&event)) {
            // _ = c.imgui.impl_sdl3.ProcessEvent(&event);
            self.input.update(event);
        }
        // self.drawImgui();

        // var iter = self.bound_descriptors.valueIterator();
        // while (iter.next()) |desc|
        //     desc.updateFn(desc.*, self.*, desc);
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
        // A minimum of Vulkan 1.2 is required for dynamic indexing
        .api_version = vk.MAKE_VERSION(1, 2, 0),
        .debug = true,
        .required_extensions = sdl_extension_slice,
    }) catch |err| {
        log.err("Failed to create vulkan instance with error: {s}", .{@errorName(err)});
        unreachable;
    };

    // surface creation
    checkSdl(sdl.Vulkan_CreateSurface(self.window, self.instance.handle, self.alloc_cbs, &self.surface));

    // Physical device creation
    const required_device_extensions: []const [*c]const u8 = &.{
        vk.KHR_SWAPCHAIN_EXTENSION_NAME,
        vk.KHR_SYNCHRONIZATION_2_EXTENSION_NAME,
        vk.KHR_DYNAMIC_RENDERING_EXTENSION_NAME,
        vk.KHR_DEPTH_STENCIL_RESOLVE_EXTENSION_NAME,
        vk.KHR_CREATE_RENDERPASS_2_EXTENSION_NAME,
        vk.KHR_PORTABILITY_SUBSET_EXTENSION_NAME,
    };
    const physical_device = vki.PhysicalDevice.select(self.allocs.std, self.instance.handle, .{
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

    var descriptor_indexing_features = vki.LogicalDevice.descriptorIndexingFeatures();
    descriptor_indexing_features.pNext = &shader_draw_parameters_features;

    const logical_device = vki.LogicalDevice.create(self.allocs.std, .{
        .physical_device = self.physical_device,
        .features = vk.PhysicalDeviceFeatures{
            .samplerAnisotropy = vk.TRUE,
        },
        .alloc_cb = self.alloc_cbs,
        .pnext = &descriptor_indexing_features,
        .device_extensions = required_device_extensions,
    }) catch @panic("Failed to create logical device");
    self.logical_device = logical_device;

    // vma allocator
    const allocator_ci = c.vma.AllocatorCreateInfo{
        .physicalDevice = self.physical_device.handle,
        .device = self.logical_device.handle,
        .instance = self.instance.handle,
    };
    checkVk(c.vma.CreateAllocator(&allocator_ci, &self.allocs.vma)) catch @panic("Failed to create VMA allocator");

    // descriptor allocator
    // BAD! field should be removed
    self.allocs.global_descriptor = descriptor.DynamicAllocator.init(self.allocs.std, self.alloc_cbs, self.logical_device.handle, descriptor.default_initial_sets, descriptor.default_pool_ratios) catch @panic("OOM");

    // Swapchain creation
    var win_width: c_int, var win_height: c_int = .{ undefined, undefined };
    checkSdl(c.sdl.GetWindowSize(self.window, &win_width, &win_height));

    self.frames.initSyncObjects(self.logical_device.handle, self.alloc_cbs);
    self.upload_context.initSyncObjects(self.logical_device.handle, self.alloc_cbs);
    self.frames.initCommands(self.logical_device.handle, self.physical_device, self.alloc_cbs);
    self.upload_context.initCommands(self.logical_device.handle, self.physical_device, self.alloc_cbs);

    self.swapchain = vki.Swapchain.create(self.allocs.std, self.allocs.vma, .{
        .physical_device = self.physical_device,
        .logical_device = self.logical_device.handle,
        .surface = self.surface,
        .old_swapchain = null,
        .vsync = true,
        .window_width = @intCast(win_width),
        .window_height = @intCast(win_height),
        .alloc_cb = self.alloc_cbs,
        .depth_buffer = true,
    }) catch @panic("failed to create swapchain");

    self.resources = self.createResourcesFn(self) catch @panic("failed to create resources");

    self.initMainRenderPass();

    self.createModelDescription();

    self.initPipeline();

    self.swapchain.createFramebuffers(
        self.allocs.std,
        self.logical_device.handle,
        self.main_render_pass,
        self.alloc_cbs,
    ) catch @panic("failed to create framebuffers");

    // self.initImgui();
}

/// Creaets description of frame models
/// coupled with PipelineDescripotion used to create main_pipeline
fn createModelDescription(self: *Self) void {
    const vertices_indices: struct { []const root.mesh.Vertex3D, []const u16 } = .{
        &[_]root.mesh.Vertex3D{
            .{
                .position = root.math.Vec3.make(-0.5, -0.5, 0.0),
                .normal = root.math.Vec3.ZERO,
                .color = root.math.Vec3.make(1.0, 0.0, 0.0),
                .uv = root.math.Vec2.make(0.0, 0.0),
            },
            .{
                .position = root.math.Vec3.make(0.5, -0.5, 0.0),
                .normal = root.math.Vec3.ZERO,
                .color = root.math.Vec3.make(0.0, 1.0, 0.0),
                .uv = root.math.Vec2.make(1.0, 0.0),
            },
            .{
                .position = root.math.Vec3.make(0.0, 0.5, 0.0),
                .normal = root.math.Vec3.ZERO,
                .color = root.math.Vec3.make(0.0, 0.0, 1.0),
                .uv = root.math.Vec2.make(0.5, 1.0),
            },
        },
        &[_]u16{ 0, 1, 2 },
    };

    var mesh = root.mesh.Mesh3D.init(self.allocs.std, vertices_indices.@"0", vertices_indices.@"1") catch @panic("OOM");
    mesh.upload(self.allocs.vma, &self.upload_context, self.logical_device);

    var test_img = root.textures.loadImageFromFile(self.allocs.vma, &self.upload_context, self.logical_device, "assets/viking_room.png") catch @panic("Failed to load image");

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
    checkVk(vk.CreateImageView(self.logical_device.handle, &image_view_ci, self.alloc_cbs, &test_img.view)) catch @panic("Failed to create image view");

    var sampler: vk.Sampler = undefined;
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

    checkVk(vk.CreateSampler(self.logical_device.handle, &ci, null, &sampler)) catch @panic("failed to create sampler");

    const materials = self.allocs.std.dupe(DescriptorIndexing.TextureInfo, &[_]DescriptorIndexing.TextureInfo{.{
        .image_view = test_img.view,
        .sampler = sampler,
    }}) catch @panic("OOM");

    const metadata_alloc = vma_usage.AllocatedBuffer.create(
        self.allocs.vma,
        @sizeOf(DescriptorIndexing.MetaData),
        vk.BUFFER_USAGE_STORAGE_BUFFER_BIT,
        c.vma.MEMORY_USAGE_CPU_TO_GPU,
        0,
    );

    var mapped_metadata: ?*anyopaque = undefined;

    checkVk(c.vma.MapMemory(self.allocs.vma, metadata_alloc.allocation, &mapped_metadata)) catch @panic("Failed to map metadata");

    const aligned_metadata: *DescriptorIndexing.MetaData = @ptrCast(@alignCast(mapped_metadata));
    aligned_metadata.* = DescriptorIndexing.MetaData{
        .index_count = 3,
        .index_offset = 0,
        .material_index = 0,
        .vertex_offset = 0,
    };

    const camera_alloc = vma_usage.AllocatedBuffer.create(
        self.allocs.vma,
        @sizeOf(root.Camera),
        vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        c.vma.MEMORY_USAGE_CPU_TO_GPU,
        0,
    );
    var mapped_camera: ?*anyopaque = undefined;
    checkVk(c.vma.MapMemory(self.allocs.vma, camera_alloc.allocation, &mapped_camera)) catch @panic("Failed to map camera");

    const aligned_camera: *root.Camera = @ptrCast(@alignCast(mapped_camera));
    aligned_camera.* = root.Camera{};

    const uniforms = self.allocs.std.dupe(vk.Buffer, &[_]vk.Buffer{camera_alloc.buffer}) catch @panic("OOM");

    self.main_pipeline_model_description = DescriptorIndexing.ModelDesc{
        .vertex_buffer = mesh.vertex_buffer.buffer,
        .index_buffer = mesh.index_buffer.buffer,
        // having undefined/null data below MUST be fixed
        .meta_data = metadata_alloc.buffer,
        .uniforms = uniforms,
        .materials = materials,
        .ranges = undefined,
    };
}

fn initPipeline(self: *Self) void {
    const vert_shader = root.shaders.createShaderModule(
        "test.vert",
        self.logical_device.handle,
        self.alloc_cbs,
    ) orelse @panic("failed to create vert shader module");
    defer vk.DestroyShaderModule(
        self.logical_device.handle,
        vert_shader,
        self.alloc_cbs,
    );

    const frag_shader = root.shaders.createShaderModule(
        "test.frag",
        self.logical_device.handle,
        self.alloc_cbs,
    ) orelse @panic("failed to create frag shader module");

    defer vk.DestroyShaderModule(
        self.logical_device.handle,
        frag_shader,
        self.alloc_cbs,
    );

    self.main_pipeline = DescriptorIndexing.init(
        self.allocs.std,
        .{
            .device = self.logical_device.handle,
            .render_pass = self.main_render_pass,
            .window_extent = self.swapchain.extent,
            .vertex_shader = vert_shader,
            .fragment_shader = frag_shader,
            .is_vertex_buffer = true,
            .is_index_buffer = true,
            .is_uniform_buffer = true,
            .is_tex2d_buffer = true,
        },
        self.alloc_cbs,
    ) catch @panic("failed to create pipeline");

    self.main_pipeline.createDescriptorPool(
        self.logical_device.handle,
        self.allocs.std,
        DescriptorIndexing.MAX_TEXTURES, // tex count
        1, // uniform buffer count
        2, // storage buffer count
        4, // max sets
        self.alloc_cbs,
    ) catch @panic("OOM");

    // idk if this is the right place to do this
    // self.descriptor_sets = self.main_pipeline.allocateDescriptorSets(
    //     self.logical_device.handle,
    //     self.allocs.std,
    //     1, //num submeshes
    // ) catch @panic("OOM");

    var tex_set: vk.DescriptorSet = undefined;
    self.main_pipeline.allocateTextureDescriptorSet(self.logical_device.handle, &tex_set);
    // const model_desc = self.createModelDesc();

    // self.main_pipeline.updateDescriptorSets(
    //     self.logical_device.handle,
    //     self.allocs.std,
    //     model_desc,
    //     &self.descriptor_sets,
    //     tex_set,
    // ) catch @panic("OOM");
}

fn initMainRenderPass(self: *Self) void {
    const color_attachment = vk.AttachmentDescription{
        .format = MAIN_RENDER_PASS_IMAGE_FORMAT,
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

    const depth_attachment = vk.AttachmentDescription{
        .format = util.findDepthFormat(self.physical_device),
        .samples = vk.SAMPLE_COUNT_1_BIT,
        .loadOp = vk.ATTACHMENT_LOAD_OP_LOAD,
        .storeOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
        .stencilLoadOp = vk.ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = vk.ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
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
        // .pDepthStencilAttachment = null,
        .pDepthStencilAttachment = &depth_attachment_ref,
    };

    const dependency = vk.SubpassDependency{
        .srcSubpass = vk.SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | vk.PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT,
        // .srcAccessMask = vk.ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        .srcAccessMask = vk.ACCESS_COLOR_ATTACHMENT_WRITE_BIT |
            vk.ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
        .dstStageMask = vk.PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT | vk.PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT,
        // .dstAccessMask = vk.ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        .dstAccessMask = vk.ACCESS_COLOR_ATTACHMENT_WRITE_BIT |
            vk.ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT,
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

    checkVk(vk.CreateRenderPass(self.logical_device.handle, &ci, self.alloc_cbs, &self.main_render_pass)) catch @panic("failed to create render pass");
}

fn drawImgui(self: *Self) void {
    c.imgui.impl_vulkan.NewFrame();
    c.imgui.impl_sdl3.NewFrame();
    c.imgui.NewFrame();

    _ = self;
    // self.pipeline_objects.runDrawImgui(.compute);
    // self.pipeline_objects.runDrawImgui(.graphics);
    c.imgui.End();
    c.imgui.Render();
}

fn drawFrame(self: *Self) void {
    var frame = self.frames.currentFrame();
    const descriptor_sets = self.main_pipeline.allocateDescriptorSets(
        self.logical_device.handle,
        self.allocs.std,
        // this should be num submeshes
        // BAD
        1,
    ) catch @panic("OOM");
    defer self.allocs.std.free(descriptor_sets);

    var texture_set: vk.DescriptorSet = undefined;
    self.main_pipeline.allocateTextureDescriptorSet(self.logical_device.handle, &texture_set);

    const present_semaphore = frame.render_semaphore;

    checkVk(vk.WaitForFences(self.logical_device.handle, 1, &frame.render_fence, vk.TRUE, std.math.maxInt(u64))) catch @panic("failed to wait for current fence");

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

    checkVk(vk.ResetFences(self.logical_device.handle, 1, &frame.render_fence)) catch @panic("failed to reset fences");
    checkVk(vk.ResetCommandBuffer(frame.main_command_buffer, 0)) catch @panic("failed to reset command buffers");

    self.recordCommandBuffer(frame, image_idx, descriptor_sets, texture_set);

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
        .pCommandBuffers = &frame.main_command_buffer,
    };

    checkVk(vk.QueueSubmit(self.logical_device.graphics_queue, 1, &submit_info, frame.render_fence)) catch @panic("failed to submit draw command buffer");

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
                self.allocs.std,
                self.allocs.vma,
                vki.SwapchainCreateOpts{
                    .physical_device = self.physical_device,
                    .logical_device = self.logical_device.handle,
                    .surface = self.surface,
                    .old_swapchain = self.swapchain.handle,
                    .vsync = true,
                    .window_width = @intCast(window_extent.width),
                    .window_height = @intCast(window_extent.height),
                    .alloc_cb = self.alloc_cbs,
                    .depth_buffer = true,
                },
                self.window,
                self.main_render_pass,
                self.alloc_cbs,
            );
            self.framebuffer_resized = false;
        } else {
            @panic("failed to present swapchain image");
        }
    };

    self.frames.incrementFrame();
}

fn recordCommandBuffer(
    self: *Self,
    frame: frames_mod.FrameData,
    image_idx: u32,
    descriptor_sets: []const vk.DescriptorSet,
    tex_set: vk.DescriptorSet,
) void {
    var begin_info = vk.CommandBufferBeginInfo{
        .sType = vk.STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
    };

    checkVk(vk.BeginCommandBuffer(frame.main_command_buffer, &begin_info)) catch @panic("failed to begin command buffer");
    defer checkVk(vk.EndCommandBuffer(frame.main_command_buffer)) catch @panic("failed to record command buffer");

    // const draw_data = Pipeline.DrawData{
    //     .resources = self.resources,
    //     .swapchain = self.swapchain,
    //     .image_index = image_idx,
    //     .descriptor_set = self.descriptor_set,
    // };

    // self.pipeline_objects.runDraw(.compute, draw_data, command_buffer);

    self.main_pipeline.bind(frame.main_command_buffer);
    {
        var render_pass_info = vk.RenderPassBeginInfo{
            .sType = vk.STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .renderPass = self.main_render_pass,
            .framebuffer = self.swapchain.framebuffers[image_idx],
            .renderArea = .{ .offset = .{
                .x = 0,
                .y = 0,
            }, .extent = vk.Extent2D{
                .height = self.swapchain.extent.height,
                .width = self.swapchain.extent.width,
            } },
        };

        if (self.swapchain.depth_resource) |res|
            vki.DepthResource.transition(frame.main_command_buffer, res);

        vk.CmdBeginRenderPass(frame.main_command_buffer, &render_pass_info, vk.SUBPASS_CONTENTS_INLINE);
        defer vk.CmdEndRenderPass(frame.main_command_buffer);

        const viewport = vk.Viewport{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(window_extent.width),
            .height = @floatFromInt(window_extent.height),
            .minDepth = 0.0,
            .maxDepth = 1.0,
        };
        vk.CmdSetViewport(frame.main_command_buffer, 0, 1, &viewport);

        const scissor = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = window_extent,
        };
        vk.CmdSetScissor(frame.main_command_buffer, 0, 1, &scissor);

        // bind set 1: textures + metadata (global, same for all submeshes)
        vk.CmdBindDescriptorSets(
            frame.main_command_buffer,
            vk.PIPELINE_BIND_POINT_GRAPHICS,
            self.main_pipeline.pipeline_layout,
            1, // set index 1
            1,
            &tex_set,
            0,
            null,
        );

        for (self.main_pipeline_model_description.ranges, 0..) |range, submesh_index| {
            // bind set 0: VB, IB, UBO for this submesh
            vk.CmdBindDescriptorSets(
                frame.main_command_buffer,
                vk.PIPELINE_BIND_POINT_GRAPHICS,
                self.main_pipeline.pipeline_layout,
                0, // set index 0
                1,
                &descriptor_sets[submesh_index],
                0,
                null,
            );

            // no vertex/index buffer binding -- hader reads from storage buffers
            // firstInstance = submesh_index so gl_BaseInstance == DrawId in shader
            vk.CmdDrawIndexed(
                frame.main_command_buffer,
                @intCast(range.index_range.range / @sizeOf(u16)),
                1, // instance count
                @intCast(range.index_range.offset / @sizeOf(u16)),
                @intCast(range.vertex_range.offset / @sizeOf(root.mesh.Vertex3D)), // vertexOffset... but unused since shader indexes manually
                @intCast(submesh_index),
            );
        }

        // c.imgui.impl_vulkan.RenderDrawData(c.imgui.GetDrawData(), command_buffer);
    }
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

    checkVk(vk.CreateDescriptorPool(self.logical_device.handle, &pool_ci, self.alloc_cbs, &self.imgui_descriptor_pool)) catch @panic("Failed to create imgui descriptor pool");

    _ = c.imgui.CreateContext(null);
    _ = c.imgui.impl_sdl3.InitForVulkan(self.window);

    var init_info = c.imgui.impl_vulkan.InitInfo{
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

    _ = c.imgui.impl_vulkan.Init(&init_info, self.main_render_pass);
    _ = c.imgui.impl_vulkan.CreateFontsTexture();
}
