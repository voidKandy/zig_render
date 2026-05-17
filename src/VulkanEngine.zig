const std = @import("std");

const root = @import("root.zig");
const vki = root.vulkan_init;
const frames_mod = root.frames;
const descriptor = root.descriptor;
const c = root.clibs;
const BoundDescriptor = root.BoundDescriptor;
const GraphicsPipeline = root.pipelines.GraphicsPipeline;
const ComputePipeline = root.pipelines.ComputePipeline;
const ResourceManager = root.ResourceManager;
const Input = root.Input;
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
};

allocs: Allocators,
alloc_cbs: ?*vk.AllocationCallbacks,

input: Input = .{},
window: *sdl.Window = undefined,
surface: vk.SurfaceKHR = undefined,
instance: vki.Instance = undefined,

physical_device: vki.PhysicalDevice = undefined,
logical_device: vki.LogicalDevice = undefined,
upload_context: vki.UploadContext = .{},

imgui_descriptor_pool: vk.DescriptorPool = undefined,

main_compute_pipeline: ComputePipeline = undefined,
main_compute_pipeline_data: ComputePipeline.AllocatedData = undefined,
main_compute_descriptor_set: vk.DescriptorSet = undefined,
main_compute_pipeline_description: ComputePipeline.Description = undefined,

main_graphics_pipeline: GraphicsPipeline = undefined,
main_graphics_pipeline_data: GraphicsPipeline.AllocatedData = undefined,
main_graphics_pipeline_systems_data: GraphicsPipeline.SystemsData = undefined,
main_graphics_descriptor_set: vk.DescriptorSet = undefined,
main_graphics_texture_descriptor_set: vk.DescriptorSet = undefined,
main_graphics_pipeline_description: GraphicsPipeline.Description = undefined,

main_render_pass: vk.RenderPass = undefined,

swapchain: vki.Swapchain = undefined,
framebuffer_resized: bool = false,
frames: frames_mod.FramesContainer(MAX_FRAMES_IN_FLIGHT) = .{},

pub fn init(
    a: std.mem.Allocator,
    alloc_cbs: ?*vk.AllocationCallbacks,
    // createResourcesFn: *const fn (*@This()) anyerror!ResourceManager,
) Self {
    return .{
        .alloc_cbs = alloc_cbs,
        .allocs = .{ .std = a },
        // .createResourcesFn = createResourcesFn,
    };
}

pub fn deinit(self: *Self) void {
    checkVk(vk.DeviceWaitIdle(self.logical_device.handle)) catch @panic("Failed to wait for device idle");

    self.swapchain.deinit(self.allocs.std, self.allocs.vma, self.logical_device.handle, self.alloc_cbs);
    log.debug("destroyed swapchain", .{});

    c.imgui.impl_vulkan.Shutdown();
    log.debug("shutdown imgui", .{});

    self.frames.deinit(self.logical_device.handle, self.alloc_cbs);
    log.debug("destroyed frames", .{});

    vk.DestroyDescriptorPool(self.logical_device.handle, self.imgui_descriptor_pool, self.alloc_cbs);
    log.debug("destroyed imgui descriptor pool", .{});

    self.main_graphics_pipeline.deinit(self.logical_device.handle, self.alloc_cbs);
    log.debug("destroyed main graphics pipeline", .{});

    self.main_graphics_pipeline_data.deinit(self.logical_device.handle, self.allocs, self.alloc_cbs);
    log.debug("destroyed main graphics pipeline data", .{});

    self.main_compute_pipeline.deinit(self.logical_device.handle, self.alloc_cbs);
    log.debug("destroyed main compute pipeline", .{});

    self.main_compute_pipeline_data.deinit(self.allocs.vma, self.logical_device.handle, self.alloc_cbs);
    log.debug("destroyed main compute pipeline data", .{});

    self.upload_context.deinit(self.logical_device.handle, self.alloc_cbs);
    log.debug("destroyed upload context", .{});

    vk.DestroyRenderPass(self.logical_device.handle, self.main_render_pass, self.alloc_cbs);
    log.debug("destroyed main render pass", .{});

    var stats: c.vma.TotalStatistics = undefined;
    c.vma.CalculateStatistics(self.allocs.vma, &stats);
    log.debug("VMA allocations still alive: {}\n", .{stats.total.statistics.allocationCount});
    log.debug("VMA bytes still allocated: {}\n", .{stats.total.statistics.allocationBytes});
    c.vma.DestroyAllocator(self.allocs.vma);
    log.debug("destroyed vma allocator", .{});

    vk.DestroyDevice(self.logical_device.handle, self.alloc_cbs);
    log.debug("destroyed logical device", .{});

    // Maybe instance should have it's own deinit function?
    if (self.instance.debug_messenger != null) {
        const destroyFn = self.instance.getDestroyDebugUtilsMessengerFn() orelse @panic("Debug messenger present but there is no destroy function?")();
        destroyFn(self.instance.handle, self.instance.debug_messenger, self.alloc_cbs);
        log.debug("destroyed debug messenger", .{});
    }

    vk.DestroySurfaceKHR(self.instance.handle, self.surface, self.alloc_cbs);
    log.debug("destroyed surface", .{});

    vk.DestroyInstance(self.instance.handle, self.alloc_cbs);
    log.debug("destroyed instance", .{});

    sdl.DestroyWindow(self.window);
    log.debug("destroyed window", .{});

    sdl.Quit();
    log.debug("quit sdl", .{});
}

pub fn run(self: *Self) void {
    self.initWindow();
    self.initVulkan();

    // var quit = false;
    var event: c.sdl.Event = undefined;

    while (!self.input.quit) {
        self.input = .{};
        while (c.sdl.PollEvent(&event)) {
            _ = c.imgui.impl_sdl3.ProcessEvent(&event);
            self.input.update(event);
        }

        self.main_graphics_pipeline_systems_data.update(
            self.main_graphics_pipeline_data,
            self.input,
            self.swapchain.extent,
        );
        self.drawImgui();
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

    self.createComputePipelineData();
    self.initMainComputePipeline();

    self.initMainRenderPass();
    self.createGraphicsPipelineData();
    self.initMainGraphicsPipeline();

    self.swapchain.createFramebuffers(
        self.allocs.std,
        self.logical_device.handle,
        self.main_render_pass,
        self.alloc_cbs,
    ) catch @panic("failed to create framebuffers");

    self.initImgui();
}

/// Creaets description of frame models
/// coupled with PipelineDescripotion used to create main_pipeline
fn createGraphicsPipelineData(self: *Self) void {
    var materials_file = root.mtl_loader.parseFile(self.allocs.std, "assets/globals.mtl") catch @panic("failed to load materials file");
    defer materials_file.deinit();

    const objects = &[_]root.obj_loader.ObjFile{
        root.obj_loader.parseFile(self.allocs.std, "assets/viking_room.obj") catch @panic("failed to read viking_room.obj"),
    };
    defer for (objects) |*o| @constCast(o).deinit();

    const default_camera = root.Camera{};

    const aspect =
        @as(f32, @floatFromInt(self.swapchain.extent.width)) /
        @as(f32, @floatFromInt(self.swapchain.extent.height));

    const camera_gpu_data = root.Camera.GPUData{
        .model = root.math.Mat4.IDENTITY,
        .view = root.math.Mat4.lookAt(
            default_camera.eye,
            root.math.Vec3.ZERO,
            root.math.Vec3.UP,
        ),
        .proj = root.math.Mat4.perspective(
            default_camera.fov,
            aspect,
            default_camera.near_plane,
            default_camera.far_plane,
        ),
    };

    self.main_graphics_pipeline_data = GraphicsPipeline.AllocatedData.create(
        self.allocs,
        &self.upload_context,
        self.logical_device,
        self.physical_device,
        .{
            .camera_gpu_data = camera_gpu_data,
            .materials_file = materials_file,
            .objects = objects,
        },
        self.alloc_cbs,
    ) catch @panic("OOM");

    self.main_graphics_pipeline_systems_data = .{
        .camera = default_camera,
    };
}

fn createComputePipelineData(self: *Self) void {
    const usages: vk.ImageUsageFlags =
        vk.IMAGE_USAGE_TRANSFER_SRC_BIT |
        vk.IMAGE_USAGE_TRANSFER_DST_BIT |
        vk.IMAGE_USAGE_STORAGE_BIT | vk.IMAGE_USAGE_COLOR_ATTACHMENT_BIT;

    var image = vma_usage.AllocatedImage.init(self.allocs.vma, MAIN_RENDER_PASS_IMAGE_FORMAT, vk.Extent3D{
        .width = self.swapchain.extent.width,
        .height = self.swapchain.extent.height,
        .depth = 1,
    }, usages);
    const view_ci = vki.imageViewCreateInfo(image.format, image.image, vk.IMAGE_ASPECT_COLOR_BIT);

    checkVk(vk.CreateImageView(self.logical_device.handle, &view_ci, self.alloc_cbs, &image.view)) catch @panic("failed to create image view");

    self.main_compute_pipeline_data = ComputePipeline.AllocatedData{
        .draw_image = image,
    };
}

fn initMainComputePipeline(self: *Self) void {
    const gradient_shader = root.shaders.createShaderModule("gradient_color.comp", self.logical_device.handle, self.alloc_cbs) orelse @panic("failed to create compute shader module");
    defer vk.DestroyShaderModule(self.logical_device.handle, gradient_shader, self.alloc_cbs);
    const sky_shader = root.shaders.createShaderModule("sky.comp", self.logical_device.handle, self.alloc_cbs) orelse @panic("failed to create compute shader module");
    defer vk.DestroyShaderModule(self.logical_device.handle, sky_shader, self.alloc_cbs);

    const gradient_data = ComputePipeline.EffectData{ .constants = .{
        .data1 = root.math.Vec4.make(1.0, 0.0, 0.0, 1.0),
        .data2 = root.math.Vec4.make(0.0, 0.0, 1.0, 1.0),
    } };
    const sky_data = ComputePipeline.EffectData{ .constants = .{
        .data1 = root.math.Vec4.make(0.1, 0.2, 0.4, 0.97),
    } };

    self.main_compute_pipeline = ComputePipeline.init(
        self.allocs.std,
        .{
            .device = self.logical_device.handle,
            .window_extent = self.swapchain.extent,
            .effects_info = &[_]struct { []const u8, ComputePipeline.EffectData, vk.ShaderModule }{
                .{
                    "gradient",
                    gradient_data,
                    gradient_shader,
                },
                .{
                    "sky",
                    sky_data,
                    sky_shader,
                },
            },
            .num_images = @as(u32, @intCast(self.swapchain.images.len)),
        },
        self.alloc_cbs,
    );

    self.main_compute_pipeline.createDescriptorPool(
        self.logical_device.handle,
        @intCast(self.swapchain.images.len),
        1, // max sets
        self.alloc_cbs,
    );

    self.main_compute_descriptor_set = self.main_compute_pipeline.allocateDescriptorSet(self.logical_device.handle);

    ComputePipeline.updateDescriptorSets(
        self.logical_device.handle,
        self.main_compute_pipeline_data,
        self.main_compute_descriptor_set,
    ) catch @panic("OOM");
    // self.descriptor_sets = self.main_graphics_pipeline.allocateDescriptorSets(
    //     self.logical_device.handle,
    //     self.allocs.std,
    //     // this should be num submeshes
    //     // BAD
    //     1,
    // ) catch @panic("OOM");

    // self.main_graphics_pipeline.allocateTextureDescriptorSet(self.logical_device.handle, &self.texture_descriptor_set);
}

fn initMainGraphicsPipeline(self: *Self) void {
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

    self.main_graphics_pipeline = GraphicsPipeline.init(
        .{
            .device = self.logical_device.handle,
            .render_pass = self.main_render_pass,
            .window_extent = self.swapchain.extent,
            .vertex_shader = vert_shader,
            .fragment_shader = frag_shader,
        },
        self.alloc_cbs,
    );

    self.main_graphics_pipeline.createDescriptorPool(
        self.logical_device.handle,
        GraphicsPipeline.MAX_TEXTURES, // tex count
        1, // uniform buffer count
        3, // storage buffer count
        3, // max sets
        self.alloc_cbs,
    );

    self.main_graphics_descriptor_set = self.main_graphics_pipeline.allocateDescriptorSet(
        self.logical_device.handle,
    ) catch @panic("OOM");

    self.main_graphics_pipeline.allocateTextureDescriptorSet(self.logical_device.handle, &self.main_graphics_texture_descriptor_set);

    GraphicsPipeline.updateDescriptorSets(
        self.logical_device.handle,
        self.allocs.std,
        self.main_graphics_pipeline_data,
        self.main_graphics_descriptor_set,
        self.main_graphics_texture_descriptor_set,
    ) catch @panic("OOM");
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

    self.main_compute_pipeline.drawImgui();
    self.main_graphics_pipeline.drawImgui(&self.main_graphics_pipeline_systems_data);

    c.imgui.Render();
}

fn drawFrame(self: *Self) void {
    var frame = self.frames.currentFrame();

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

    self.recordCommandBuffer(frame, image_idx);

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
) void {
    var begin_info = vk.CommandBufferBeginInfo{
        .sType = vk.STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
    };

    checkVk(vk.BeginCommandBuffer(frame.main_command_buffer, &begin_info)) catch @panic("failed to begin command buffer");
    defer checkVk(vk.EndCommandBuffer(frame.main_command_buffer)) catch @panic("failed to record command buffer");

    self.main_compute_pipeline.bind(frame.main_command_buffer);

    self.main_compute_pipeline.recordCommands(
        self.main_compute_pipeline_data,
        self.swapchain,
        image_idx,
        self.main_compute_descriptor_set,
        frame.main_command_buffer,
    );

    self.main_graphics_pipeline.bind(frame.main_command_buffer);

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
        self.main_graphics_pipeline.pipeline_layout,
        1, // set index 1
        1,
        &self.main_graphics_texture_descriptor_set,
        0,
        null,
    );

    for (self.main_graphics_pipeline_data.mesh_ranges, 0..) |range, idx| {
        // bind set 0: VB, IB, UBO for this submesh
        vk.CmdBindDescriptorSets(
            frame.main_command_buffer,
            vk.PIPELINE_BIND_POINT_GRAPHICS,
            self.main_graphics_pipeline.pipeline_layout,
            0, // set index 0
            1,
            &self.main_graphics_descriptor_set,
            0,
            null,
        );
        vk.CmdDraw(
            frame.main_command_buffer,
            @as(u32, @intCast(range.index_range.range)),
            1, // num instances
            0,
            // @as(u32, @intCast(range.vertex_range.offset)),
            @as(u32, @intCast(idx)), // first instance
        );
        // vk.CmdBindIndexBuffer(
        //     frame.main_command_buffer,
        //     self.main_graphics_pipeline_data.meshes_index_buffer.buffer,
        //     range.index_range.offset * @sizeOf(u16),
        //     vk.INDEX_TYPE_UINT16,
        // );
        // vk.CmdDrawIndexed(
        //     frame.main_command_buffer,
        //     @intCast(range.index_range.range),
        //     1, // instance count
        //     @intCast(range.index_range.offset),
        //     @intCast(range.vertex_range.offset), // vertexOffset... but unused since shader indexes manually
        //     @intCast(idx),
        // );

        c.imgui.impl_vulkan.RenderDrawData(c.imgui.GetDrawData(), frame.main_command_buffer);
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
