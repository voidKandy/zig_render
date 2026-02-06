const std = @import("std");
const log = std.log.scoped(.VulkanEngine);
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
const PipelineObject = @import("PipelineObject.zig");
const ResourceManager = @import("ResourceManager.zig");
const BackgroundEffects = @import("pipelines/BackgroundEffects.zig");
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
global_descriptor_allocator: descriptor.Allocator = undefined,
resources: ResourceManager = undefined,
/// resources cannot be created until vulkan is initialized, so
/// this is passed at initialization to create resources
createResourcesFn: *const fn (*@This()) anyerror!void,

window: *sdl.Window = undefined,
surface: vk.SurfaceKHR = undefined,
instance: vki.Instance = undefined,

physical_device: vki.PhysicalDevice = undefined,
logical_device: vki.LogicalDevice = undefined,

swapchain: vki.Swapchain = undefined,
framebuffer_resized: bool = false,
frames: frames_mod.FramesContainer(MAX_FRAMES_IN_FLIGHT) = .{},
frame_descriptor_pool: vk.DescriptorPool = undefined,
imgui_descriptor_pool: vk.DescriptorPool = undefined,

graphics_pipelines: std.StringHashMap(PipelineObject) = undefined,
background_effects: PipelineObject = undefined,

upload_context: vki.UploadContext = .{},

// add crete pipelienes as a function parameter
pub fn init(a: std.mem.Allocator, createResourcesFn: *const fn (*@This()) anyerror!void) Self {
    return .{
        .allocator = a,
        .global_descriptor_allocator = .init(a, vk_alloc_cbs),
        .createResourcesFn = createResourcesFn,
    };
}

pub fn deinit(self: *Self) void {
    checkVk(vk.DeviceWaitIdle(self.logical_device.handle)) catch @panic("Failed to wait for device idle");

    self.swapchain.deinit(self.allocator, self.vma_allocator, self.logical_device.handle, vk_alloc_cbs);
    c.imgui.impl_vulkan.Shutdown();

    self.frames.deinit(self.logical_device.handle, self.vma_allocator, vk_alloc_cbs);
    vk.DestroyDescriptorPool(self.logical_device.handle, self.imgui_descriptor_pool, vk_alloc_cbs);
    vk.DestroyDescriptorPool(self.logical_device.handle, self.frame_descriptor_pool, vk_alloc_cbs);

    const allocs = PipelineObject.Allocators{
        .std = self.allocator,
        .vma = self.vma_allocator,
        .descriptor = &self.global_descriptor_allocator,
    };

    var grphx_iter = self.graphics_pipelines.valueIterator();
    while (grphx_iter.next()) |node|
        node.deinit(allocs, self.logical_device.handle, vk_alloc_cbs);
    self.graphics_pipelines.deinit();

    self.background_effects.deinit(allocs, self.logical_device.handle, vk_alloc_cbs);

    self.upload_context.deinit(self.logical_device.handle, vk_alloc_cbs);

    // texture should have deinit?

    self.resources.deinit(self.allocator, self.vma_allocator, self.logical_device.handle, vk_alloc_cbs);

    self.global_descriptor_allocator.deinit(self.logical_device.handle);
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
            _ = c.imgui.impl_sdl3.ProcessEvent(&event);
        }

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

    self.frames.initSyncObjects(self.logical_device.handle, vk_alloc_cbs);
    self.upload_context.initSyncObjects(self.logical_device.handle, vk_alloc_cbs);
    self.frames.initCommands(self.logical_device.handle, self.physical_device, vk_alloc_cbs);
    self.upload_context.initCommands(self.logical_device.handle, self.physical_device, vk_alloc_cbs);
    // self.frames.initDescriptors(self.allocator, self.logical_device.handle, vk_alloc_cbs);
    self.frames.initDescriptorSetLayouts(self.logical_device.handle, vk_alloc_cbs);

    self.createResourcesFn(self) catch @panic("failed to create resources");

    // self.initResources();
    self.initPipelineObjects();

    // TODO
    // think about how render passes should be managed
    self.swapchain.createFramebuffers(
        self.allocator,
        self.logical_device.handle,
        self.mainRenderPass(),
        vk_alloc_cbs,
    ) catch @panic("failed to create framebuffers");

    // BAD
    // should be moved to init resources
    self.createDescriptorPool();
    self.frames.initBuffers(self.vma_allocator);
    self.frames.allocateDescriptorSets(self.logical_device.handle, self.frame_descriptor_pool);

    const texture_id = self.resources.getId(.texture, 0) orelse @panic("No texture?");
    const texture_resource = self.resources.query(texture_id) orelse @panic("malformed resources");
    const sampler_id = self.resources.getId(.sampler, 0) orelse @panic("No sampler?");
    const sampler_resource = self.resources.query(sampler_id) orelse @panic("malformed resources");
    self.frames.updateDescriptorSets(self.logical_device.handle, texture_resource.texture.image_view, sampler_resource.sampler);
    self.initImgui();
}

/// the `main` render pass is the 0Th render pass stored in resources
fn mainRenderPass(self: *Self) vk.RenderPass {
    const id = self.resources.getId(.render_pass, 0) orelse @panic("RESOURCES HAVE 0 RENDER PASSES");
    return (self.resources.query(id) orelse @panic("MALFORMED RESOURCES")).render_pass;
}

fn initPipelineObjects(self: *Self) void {
    const init_data = PipelineObject.InitData{
        .swapchain_extent = self.swapchain.extent,
        .resources = self.resources,
    };
    const allocs = PipelineObject.Allocators{
        .std = self.allocator,
        .vma = self.vma_allocator,
        .descriptor = &self.global_descriptor_allocator,
    };
    self.graphics_pipelines = .init(self.allocator);

    inline for ([_]struct { []const u8, type }{
        .{ "triangle", @import("pipelines/Triangle.zig") },
    }) |v| {
        var entry = PipelineObject.create(v.@"1", self.allocator) catch @panic("OOM");
        // BAD
        // This should be done in some other way
        // eventually meshes should be initialized with some string key to keep track of ids
        const resources = &[_]ResourceManager.ResourceID{ self.resources.getId(.mesh3D, 0).?, self.resources.getId(.render_pass, 0).? };
        entry.init(
            allocs,
            init_data,
            resources,
            self.logical_device,
            vk_alloc_cbs,
        );
        self.graphics_pipelines.put(v.@"0", entry) catch @panic("OOM");
    }

    {
        const background_image = self.resources.getId(.image, 0).?;
        self.background_effects = PipelineObject.create(BackgroundEffects, self.allocator) catch @panic("OOM");
        self.background_effects.init(
            allocs,
            init_data,
            &[_]ResourceManager.ResourceID{background_image},
            self.logical_device,
            vk_alloc_cbs,
        );
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

    checkVk(vk.CreateDescriptorPool(self.logical_device.handle, &ci, vk_alloc_cbs, &self.frame_descriptor_pool)) catch @panic("failed to create descriptor pool");
}

fn recordCommandBuffer(self: *Self, command_buffer: vk.CommandBuffer, image_idx: u32) void {
    var begin_info = vk.CommandBufferBeginInfo{
        .sType = vk.STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
    };

    checkVk(vk.BeginCommandBuffer(command_buffer, &begin_info)) catch @panic("failed to begin command buffer");
    defer checkVk(vk.EndCommandBuffer(command_buffer)) catch @panic("failed to record command buffer");

    const draw_data = PipelineObject.DrawData{
        .resources = self.resources,
        .swapchain = self.swapchain,
        .image_index = image_idx,
    };

    self.background_effects.draw(draw_data, command_buffer);

    {
        var render_pass_info = vk.RenderPassBeginInfo{
            .sType = vk.STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .renderPass = self.mainRenderPass(),
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

        var iter = self.graphics_pipelines.valueIterator();
        while (iter.next()) |entry|
            entry.draw(draw_data, command_buffer);

        c.imgui.impl_vulkan.RenderDrawData(c.imgui.GetDrawData(), command_buffer);
    }
}

fn drawImgui(self: *Self) void {
    c.imgui.impl_vulkan.NewFrame();
    c.imgui.impl_sdl3.NewFrame();
    c.imgui.NewFrame();
    self.background_effects.drawImgui();
    c.imgui.End();
    c.imgui.Render();
}

fn updateFrameData(self: *Self, frame: frames_mod.FrameData) void {
    rotateCamera(frame, self.swapchain.extent);
}

fn drawFrame(self: *Self) void {
    var current_frame = self.frames.currentFrame();
    self.updateFrameData(current_frame);

    const present_semaphore = current_frame.render_semaphore;

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
                self.mainRenderPass(),
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
fn rotateCamera(frame: frames_mod.FrameData, swapchain_extent: vk.Extent2D) void {
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
        @as(f32, @floatFromInt(swapchain_extent.width)) /
        @as(f32, @floatFromInt(swapchain_extent.height));
    var ubo = frames_mod.GPUCameraData{
        .model = Mat4.IDENTITY.rotate(Vec3.make(0.0, 0.0, 1.0), time * 1.0),
        .view = Mat4.lookAt(Vec3.make(2.0, 2.0, 2.0), Vec3.make(0.0, 0.0, 0.0), Vec3.make(0.0, 0.0, 1.0)),
        .proj = Mat4.perspective(fov, aspect, near_plane, far_plane),
    };

    ubo.proj.j.y *= -1;

    const aligned_data: *frames_mod.GPUCameraData = @ptrCast(@alignCast(frame.camera_data.mapped));
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

    _ = c.imgui.impl_vulkan.Init(&init_info, self.mainRenderPass());
    _ = c.imgui.impl_vulkan.CreateFontsTexture();
}
