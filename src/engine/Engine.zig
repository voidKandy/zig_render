const std = @import("std");
const core = @import("../root.zig");
const c = core.clibs;
const vki = core.bindings.vulkan_init;
const frames_mod = core.engine.frames;
const Mesh3DPipeline = core.engine.pipelines.Mesh3DPipeline;
const Mesh2DPipeline = core.engine.pipelines.Mesh2DPipeline;
const Input = core.engine.Input;
const vma_usage = core.bindings.vma_usage;
const math_mod = core.lib.math;
const util = core.bindings.vulkan_util;
const vk = c.vk;
const checkVk = vki.checkVk;
const sdl = c.sdl;
const checkSdl = core.bindings.sdl_usage.checkSdl;
const VkError = vki.VkError;
const log = std.log.scoped(.Engine);

const MAX_FRAMES_IN_FLIGHT: usize = 2;
pub const MAIN_RENDER_PASS_IMAGE_FORMAT = vk.FORMAT_R16G16B16A16_SFLOAT;
const INITIAL_WINDOW_EXTENT = vk.Extent2D{ .width = 1600, .height = 900 };

const Self = @This();

allocs: core.engine.Allocators,
alloc_cbs: ?*vk.AllocationCallbacks,
io: std.Io,

input: Input = .{},
window: *sdl.Window = undefined,
surface: vk.SurfaceKHR = undefined,
instance: vki.Instance = undefined,

physical_device: vki.PhysicalDevice = undefined,
logical_device: vki.LogicalDevice = undefined,
upload_context: vki.UploadContext = .{},

imgui_descriptor_pool: vk.DescriptorPool = undefined,

allocated_resources: core.resources.Manager.AllocatedData = undefined,
resources: core.resources.Manager = undefined,

world: core.engine.world.GameWorld,

mesh_manipulation_system: core.engine.systems.MeshManipulation = undefined,
maze_system: core.engine.systems.Maze = undefined,
camera_system: core.engine.systems.Camera = undefined,
draw_bg_system: core.engine.systems.DrawBackground = undefined,

mesh3D_pipeline: Mesh3DPipeline = undefined,
mesh3D_pipeline_description: Mesh3DPipeline.Description = undefined,

mesh2D_pipeline: Mesh2DPipeline = undefined,
mesh2D_pipeline_description: Mesh2DPipeline.Description = undefined,

main_render_pass: vk.RenderPass = undefined,

swapchain: vki.Swapchain = undefined,
framebuffer_resized: bool = false,
frames: frames_mod.FramesContainer(MAX_FRAMES_IN_FLIGHT) = .{},

pub fn init(
    a: std.mem.Allocator,
    io: std.Io,
    resources_ci: core.resources.Manager.CreateInfo,
    alloc_cbs: ?*vk.AllocationCallbacks,
) Self {
    var self = @This(){
        .allocs = .{ .std = a },
        .alloc_cbs = alloc_cbs,
        .io = io,
        .world = core.engine.world.GameWorld.init(a) catch @panic("OOM"),
        .resources = core.resources.Manager.create(
            a,
            resources_ci,
        ) catch @panic("failed resources init"),
    };

    self.initWindow();
    self.initVulkan();

    // BAD
    // I hate this is called here
    self.resources.materials.initSampler(
        self.logical_device.handle,
        vk.SamplerCreateInfo{
            .sType = vk.STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .magFilter = vk.FILTER_NEAREST,
            .minFilter = vk.FILTER_NEAREST,
            .addressModeU = vk.SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeV = vk.SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeW = vk.SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
        },
    );

    return self;
}

pub fn deinit(self: *Self) void {
    checkVk(vk.DeviceWaitIdle(self.logical_device.handle)) catch @panic("Failed to wait for device idle");

    self.swapchain.deinit(self.allocs.std, self.allocs.vma, self.logical_device.handle, self.alloc_cbs);
    log.debug("destroyed swapchain", .{});

    c.imgui.impl_vulkan.Shutdown();

    self.frames.deinit(self.logical_device.handle, self.alloc_cbs);
    log.debug("destroyed frames", .{});

    vk.DestroyDescriptorPool(self.logical_device.handle, self.imgui_descriptor_pool, self.alloc_cbs);
    log.debug("destroyed imgui descriptor pool", .{});

    // self.global_data.deinit(self.logical_device.handle, self.alloc_cbs);
    self.resources.deinit(self.allocs.std, self.logical_device.handle, self.alloc_cbs);
    self.allocated_resources.deinit(self.allocs, self.logical_device.handle, self.alloc_cbs);

    self.mesh3D_pipeline.deinit(self.logical_device.handle, self.alloc_cbs);
    log.debug("destroyed mesh pipeline", .{});
    self.mesh_manipulation_system.deinit(self.allocs);
    self.maze_system.deinit(self.allocs.std, self.logical_device.handle, self.alloc_cbs);
    self.draw_bg_system.deinit(self.logical_device.handle, self.alloc_cbs);

    self.mesh2D_pipeline.deinit(self.logical_device.handle, self.alloc_cbs);
    log.debug("destroyed hud pipeline", .{});

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
    // var quit = false;
    var event: c.sdl.Event = undefined;

    while (!self.input.quit) {
        self.input = .{};
        while (c.sdl.PollEvent(&event)) {
            _ = c.imgui.impl_sdl3.ProcessEvent(&event);
            self.input.update(event);
        }

        // should be abstracted to a function later
        if (self.input.isDown(.Escape)) {
            const is_relative_mouse = sdl.GetWindowRelativeMouseMode(self.window) == true;
            _ = sdl.SetWindowRelativeMouseMode(self.window, !is_relative_mouse);
        }

        // there seems like theres room for some system container type
        self.camera_system.update(self.*);
        self.maze_system.update();
        self.maze_system.trySyncResources(
            self.allocated_resources,
        );
        self.mesh_manipulation_system.trySyncResources(
            self.resources,
            self.allocated_resources,
            &self.world,
        );

        self.camera_system.trySyncResources(self.allocated_resources);
        self.drawImgui();
        self.drawFrame();
    }

    _ = vk.DeviceWaitIdle(self.logical_device.handle);
}

fn initWindow(self: *Self) void {
    checkSdl(sdl.Init(sdl.INIT_VIDEO));
    const window = sdl.CreateWindow("Vulkan", INITIAL_WINDOW_EXTENT.width, INITIAL_WINDOW_EXTENT.height, sdl.WINDOW_VULKAN | sdl.WINDOW_RESIZABLE) orelse @panic("Failed to create SDL window");
    _ = sdl.SetWindowRelativeMouseMode(window, true);

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
    const physical_device = vki.PhysicalDevice.select(self.allocs.std, self.instance.handle, .{
        .min_api_version = vk.MAKE_VERSION(1, 1, 0),
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

    const required_device_extensions: []const [*c]const u8 = &.{
        vk.KHR_SWAPCHAIN_EXTENSION_NAME,
        vk.KHR_SYNCHRONIZATION_2_EXTENSION_NAME,
        vk.KHR_DYNAMIC_RENDERING_EXTENSION_NAME,
        vk.KHR_DEPTH_STENCIL_RESOLVE_EXTENSION_NAME,
        vk.KHR_CREATE_RENDERPASS_2_EXTENSION_NAME,
        vk.KHR_PORTABILITY_SUBSET_EXTENSION_NAME,
    };
    const logical_device = vki.LogicalDevice.create(self.allocs.std, .{
        .physical_device = self.physical_device,
        .features = vk.PhysicalDeviceFeatures{
            .samplerAnisotropy = vk.TRUE,
            // to allow for the line graphics pipeline
            .fillModeNonSolid = vk.TRUE,
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
    self.initMainRenderPass();
    self.swapchain.createFramebuffers(
        self.allocs.std,
        self.logical_device.handle,
        self.main_render_pass,
        self.alloc_cbs,
    ) catch @panic("failed to create framebuffers");
}

pub fn addSystemCreateDataToResourceManager(self: *@This()) void {
    self.maze_system.addCreateData(self.allocs.std, &self.resources) catch @panic("OOM");
    self.camera_system.addCreateData(self.allocs.std, &self.resources) catch @panic("OOM");
    self.draw_bg_system.addCreateData(self.allocs.std, &self.resources) catch @panic("OOM");
}

// These bindings can be the same because they are not in the
// same descriptor set
// TODO
// move these to where they are actually encapsulated
const TEXTURE_SET_BINDING: u32 = 1;
const MESHES_2D_METADATA_SET_BINDING: u32 = 0;
/// Allocates resources, creates descriptor layouts/pool
/// AND associates meshes with entities.
/// The latter half of this needs to be moved to its own function
/// when entity/component management is figured out
pub fn allocateResources(self: *Self) void {
    self.resources.materials.createDescriptorSetLayout(
        TEXTURE_SET_BINDING,
        self.logical_device.handle,
        self.alloc_cbs,
    );

    self.resources.meshes3D.createDescriptorSetLayout(
        core.resources.Meshes3D.DEFAULT_BINDINGS,
        self.logical_device.handle,
        self.alloc_cbs,
    );

    self.resources.meshes2D.createDescriptorSetLayout(
        MESHES_2D_METADATA_SET_BINDING,
        self.logical_device.handle,
        self.alloc_cbs,
    );

    for (self.resources.meshes3D.meshes.items) |handle| {
        var ent = self.world.entities.register(null) catch @panic("OOM");
        ent.addComponent(.mesh3D, core.engine.world.Mesh3DComponent{
            .handle = handle,
        });
    }
    for (self.resources.meshes2D.ranges.items) |ranges| {
        var ent = self.world.entities.register(null) catch @panic("OOM");
        ent.addComponent(.mesh2D, core.engine.world.Mesh2DComponent{
            .ranges = ranges,
        });
    }

    // should be some logic piped in for systems being able to register any sets they
    // need to
    core.engine.systems.Maze.registerSets(
        self.allocs.std,
        self.logical_device.handle,
        &self.resources,
        self.alloc_cbs,
    ) catch @panic("OOM");
    core.engine.systems.Camera.registerSets(
        self.allocs.std,
        self.logical_device.handle,
        &self.resources,
        self.alloc_cbs,
    ) catch @panic("OOM");

    core.engine.systems.DrawBackground.registerSets(
        self.allocs.std,
        self.logical_device.handle,
        &self.resources,
        self.alloc_cbs,
    ) catch @panic("OOM");
    // BAD??
    const max_sets = 16;
    self.allocated_resources = self.resources.upload(
        self.allocs,
        max_sets,
        &self.upload_context,
        self.logical_device,
        self.physical_device,
        self.alloc_cbs,
    ) catch @panic("OOM");

    self.allocated_resources.materials.updateStaticTextureSet(
        self.allocs.std,
        self.logical_device.handle,
        TEXTURE_SET_BINDING,
    ) catch @panic("OOM");

    self.allocated_resources.mapped_buffers.updateBufferSet(
        self.logical_device.handle,
        core.engine.systems.Camera.CAMERA_SET_NAME,
    );

    self.allocated_resources.mapped_buffers.updateBufferSet(
        self.logical_device.handle,
        core.engine.systems.Maze.COMPUTE_MAZE_SET_NAME,
    );

    self.allocated_resources.materials.updateWritableTextureSet(
        self.logical_device.handle,
        core.engine.systems.Maze.COMPUTE_MAZE_SET_NAME,
    );

    self.allocated_resources.materials.updateWritableTextureSet(
        self.logical_device.handle,
        core.engine.systems.DrawBackground.BACKGROUND_SET_NAME,
    );
}

pub fn initSystems(self: *Self, maze_system_ci: core.engine.systems.Maze.CreateInfo) void {
    self.mesh_manipulation_system = .{};
    self.maze_system = core.engine.systems.Maze.init(self.allocs.std, maze_system_ci) catch @panic("failed to create mesh maze");
    self.camera_system = core.engine.systems.Camera.init(.{}, self.swapchain.extent) catch @panic("failed to create mesh maze");
    self.draw_bg_system = core.engine.systems.DrawBackground.init(self.swapchain.extent);
}

pub fn initPipelines(
    self: *Self,
) void {
    self.initImgui();

    self.maze_system.initPipeline(self.resources, self.alloc_cbs);
    self.draw_bg_system.initPipeline(self.logical_device.handle, self.resources, self.alloc_cbs);

    self.initMesh3DPipeline();
    self.initMesh2DPipeline();
}

fn initMesh3DPipeline(self: *Self) void {
    const vert_shader = core.engine.shaders.createShaderModule(
        "mesh3D.vert",
        self.logical_device.handle,
        self.alloc_cbs,
    ) orelse @panic("failed to create vert shader module");
    defer vk.DestroyShaderModule(
        self.logical_device.handle,
        vert_shader,
        self.alloc_cbs,
    );

    const frag_shader = core.engine.shaders.createShaderModule(
        "mesh3D.frag",
        self.logical_device.handle,
        self.alloc_cbs,
    ) orelse @panic("failed to create frag shader module");

    defer vk.DestroyShaderModule(
        self.logical_device.handle,
        frag_shader,
        self.alloc_cbs,
    );

    self.mesh3D_pipeline = Mesh3DPipeline.init(
        .{
            .camera_descriptor_set_layout = self.resources.mapped_buffers.buffer_set_layouts.get(core.engine.systems.Camera.CAMERA_SET_NAME).?.layout,
            .texture_set_layout = self.resources.materials.all_textures_descriptor_set_layout,
            .meshes_set_layout = self.resources.meshes3D.descriptor_set_layout,
            .device = self.logical_device.handle,
            .render_pass = self.main_render_pass,
            .window_extent = self.swapchain.extent,
            .vertex_shader = vert_shader,
            .fragment_shader = frag_shader,
        },
        // self.allocated_resources,
        self.alloc_cbs,
    );

    self.allocated_resources.meshes3D.updateDescriptorSet(
        self.logical_device.handle,
        core.resources.Meshes3D.DEFAULT_BINDINGS,
    ) catch @panic("OOM");
}

fn initMesh2DPipeline(self: *Self) void {
    // TODO
    // shader code should live inside the pipeline modules they belong to
    const vert_shader = core.engine.shaders.createShaderModule(
        "mesh2D.vert",
        self.logical_device.handle,
        self.alloc_cbs,
    ) orelse @panic("failed to create hud vert shader module");
    defer vk.DestroyShaderModule(
        self.logical_device.handle,
        vert_shader,
        self.alloc_cbs,
    );
    const frag_shader = core.engine.shaders.createShaderModule(
        "mesh2D.frag",
        self.logical_device.handle,
        self.alloc_cbs,
    ) orelse @panic("failed to create hud frag shader module");
    defer vk.DestroyShaderModule(
        self.logical_device.handle,
        frag_shader,
        self.alloc_cbs,
    );
    self.mesh2D_pipeline = Mesh2DPipeline.init(
        .{
            .device = self.logical_device.handle,
            .camera_descriptor_set_layout = self.resources.mapped_buffers.buffer_set_layouts.get(core.engine.systems.Camera.CAMERA_SET_NAME).?.layout,
            .texture_set_layout = self.resources.materials.all_textures_descriptor_set_layout,
            .meshes_set_layout = self.resources.meshes2D.descriptor_set_layout,
            .render_pass = self.main_render_pass,
            .window_extent = self.swapchain.extent,
            .vert_shader = vert_shader,
            .frag_shader = frag_shader,
        },
        self.alloc_cbs,
    );

    self.allocated_resources.meshes2D.updateDescriptorSet(
        self.logical_device.handle,
        MESHES_2D_METADATA_SET_BINDING,
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

    const is_relative_mouse = c.sdl.GetWindowRelativeMouseMode(self.window) == true;
    c.imgui.Text(if (is_relative_mouse) "Mouse: Relative" else "Mouse: Absolute");
    c.imgui.Text("Press escape to toggle mouse mode");

    self.draw_bg_system.drawImgui();

    self.mesh_manipulation_system.drawImgui(
        self.allocs.std,
        &self.mesh3D_pipeline,
        &self.world,
        self.resources,
        self.allocated_resources,
    );
    self.maze_system.drawImgui(
        // self.compute_maze_descriptor_sets.ui,
    );
    self.camera_system.drawImgui();

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
            VkError.SuboptimalKHR => {},
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
                    .window_width = @intCast(INITIAL_WINDOW_EXTENT.width),
                    .window_height = @intCast(INITIAL_WINDOW_EXTENT.height),
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

    self.maze_system.pipeline.bind(frame.main_command_buffer);
    self.maze_system.pipeline.recordCommands(
        self.allocated_resources,
        self.allocated_resources.mapped_buffers.buffer_sets.get(core.engine.systems.Camera.CAMERA_SET_NAME).?.set,
        self.allocated_resources.materials.writable_textures_descriptor_sets.get(core.engine.systems.Maze.COMPUTE_MAZE_SET_NAME).?.set,
        self.allocated_resources.mapped_buffers.buffer_sets.get(core.engine.systems.Maze.COMPUTE_MAZE_SET_NAME).?.set,
        self.maze_system,
        frame.main_command_buffer,
    );
    self.draw_bg_system.pipeline.bind(frame.main_command_buffer);
    self.draw_bg_system.pipeline.recordCommands(
        self.allocated_resources,
        // self.background_pipeline_data,
        self.swapchain,
        image_idx,
        self.allocated_resources.materials.writable_textures_descriptor_sets.get(core.engine.systems.DrawBackground.BACKGROUND_SET_NAME).?.set,
        frame.main_command_buffer,
    );

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
        .width = @floatFromInt(self.swapchain.extent.width),
        .height = @floatFromInt(self.swapchain.extent.height),
        .minDepth = 0.0,
        .maxDepth = 1.0,
    };
    vk.CmdSetViewport(frame.main_command_buffer, 0, 1, &viewport);

    const scissor = vk.Rect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = self.swapchain.extent,
    };
    vk.CmdSetScissor(frame.main_command_buffer, 0, 1, &scissor);

    self.mesh3D_pipeline.bind(frame.main_command_buffer);
    self.mesh3D_pipeline.recordCommands(
        &self.world,
        self.allocated_resources.mapped_buffers.buffer_sets.get(core.engine.systems.Camera.CAMERA_SET_NAME).?.set,
        self.allocated_resources.meshes3D.descriptor_set,
        self.allocated_resources.materials.all_textures_descriptor_set,
        frame.main_command_buffer,
    );

    self.mesh2D_pipeline.bind(frame.main_command_buffer);
    self.mesh2D_pipeline.recordCommands(
        &self.world,
        self.swapchain.extent,
        self.allocated_resources,
        self.allocated_resources.mapped_buffers.buffer_sets.get(core.engine.systems.Camera.CAMERA_SET_NAME).?.set,
        self.allocated_resources.meshes2D.descriptor_set,
        self.allocated_resources.materials.all_textures_descriptor_set,
        frame.main_command_buffer,
    );
    c.imgui.impl_vulkan.RenderDrawData(c.imgui.GetDrawData(), frame.main_command_buffer);
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
