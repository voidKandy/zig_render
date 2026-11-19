const std = @import("std");
const core = @import("../root.zig");
const c = core.clibs;
const vku = core.bindings.vulkan_usage;
const frames_mod = core.engine.frames;
const Input = core.engine.Input;
const vma_usage = core.bindings.vma_usage;
const math_mod = core.lib.math;
const vk = c.vk;
const checkVk = vku.checkVk;
const sdl = c.sdl;
const checkSdl = core.bindings.sdl_usage.checkSdl;
const VkError = vku.VkError;
const log = std.log.scoped(.Engine);

const MAX_FRAMES_IN_FLIGHT: usize = 2;
const INITIAL_WINDOW_EXTENT = vk.Extent2D{ .width = 1600, .height = 900 };

const Engine = @This();

pub fn EngineType(
    Systems: type,
    World: type,
) type {
    std.debug.assert(World.IS_ENTITY_STORE);
    std.debug.assert(Systems.IS_SYSTEM_MANAGER);

    return struct {
        systems: Systems,
        world: World,

        /// Expects caller to manage memory of systems and world
        const _ = @This();
        pub fn run(
            self: *@This(),
            core_engine: *Engine,
        ) void {
            var event: c.sdl.Event = undefined;
            var last_time = std.Io.Timestamp.now(core_engine.io, .real).toNanoseconds();
            _ = sdl.SetWindowRelativeMouseMode(core_engine.window, false);

            core_engine.renderer.instancesFromWorld(World, core_engine.allocs.std, &self.world) catch
                @panic("OOM");

            while (!core_engine.input.quit) {
                core_engine.input = .{};
                while (c.sdl.PollEvent(&event)) {
                    _ = c.imgui.impl_sdl3.ProcessEvent(&event);
                    core_engine.input.update(event);
                }

                const now = std.Io.Timestamp.now(core_engine.io, .real).toNanoseconds();
                const dt: f32 = @as(f32, @floatFromInt(now - last_time)) / @as(f32, @floatFromInt(std.time.ns_per_s));
                last_time = now;

                self.systems.update(&self.world, .fromEngine(core_engine, dt));

                // TODO
                // the function that take World, world assume World is an ecs.EntityStore
                core_engine.physics.update(World, &self.world);

                core_engine.renderer.instancesFromWorld(World, core_engine.allocs.std, &self.world) catch
                    @panic("OOM");
                core_engine.renderer.syncResources(&core_engine.allocated_resources);

                self.systems.syncResources(core_engine.allocated_resources);
                self.systems.syncWorld(core_engine.allocs.std, &self.world) catch
                    @panic("OOM");

                self.drawImgui(core_engine);
                self.drawFrame(core_engine);
            }

            _ = vk.DeviceWaitIdle(core_engine.logical_device.handle);
        }

        pub fn registerSets(
            self: *@This(),
            core_engine: *Engine,
        ) void {
            core_engine.renderer.registerSetsAndBuffers(
                core_engine.allocs.std,
                core_engine.logical_device.handle,
                &core_engine.resources,
                core_engine.alloc_cbs,
            ) catch @panic("OOM");
            core_engine.resources.createSamplersAndDescriptorSetLayouts(core_engine.logical_device.handle, core_engine.alloc_cbs);

            self.systems.registerSets(
                core_engine.allocs.std,
                core_engine.logical_device.handle,
                &core_engine.resources,
                core_engine.alloc_cbs,
            ) catch @panic("OOM");
        }

        pub fn updateSets(
            self: *@This(),
            core_engine: *Engine,
        ) void {
            core_engine.allocated_resources.meshes3D.updateDescriptorSet(
                core_engine.logical_device.handle,
            ) catch @panic("OOM");

            core_engine.allocated_resources.materials.updateStaticTextureSet(
                core_engine.resources.materials,
                core_engine.allocs.std,
                core_engine.logical_device.handle,
                core.resources.Materials.DEFAULT_BINDINGS,
            ) catch @panic("OOM");

            core_engine.renderer.updateSets(core_engine.logical_device.handle, &core_engine.allocated_resources);

            // BAD?
            self.systems.plexe.Debug.?.bind(
                core_engine.allocs.std,
                &core_engine.resources,
                &core_engine.allocated_resources,
            ) catch @panic("OOM");
            self.systems.plexe.Debug.?.bindAttachments(
                core_engine.allocs.std,
                &core_engine.renderer.swapchain,
                &core_engine.allocated_resources,
            ) catch @panic("OOM");

            self.systems.updateSets(core_engine.logical_device.handle, &core_engine.allocated_resources);
        }

        pub fn initPipelines(
            self: *@This(),
            core_engine: *Engine,
        ) void {
            const graphics_common = core.engine.pipelines.Common{
                .device = core_engine.logical_device.handle,
                .render_pass = core_engine.renderer.main_render_pass,
                .window_extent = core_engine.renderer.swapchain.extent,
            };

            core_engine.renderer.initPipelines(graphics_common, &core_engine.resources, core_engine.alloc_cbs);
            self.systems.initComputePipelines(core_engine.logical_device.handle, core_engine.resources, core_engine.alloc_cbs);
        }

        pub fn drawImgui(self: *@This(), core_engine: *Engine) void {
            c.imgui.impl_vulkan.NewFrame();
            c.imgui.impl_sdl3.NewFrame();
            c.imgui.NewFrame();
            const ctx = core.engine.systems.DrawImguiContext.fromEngine(core_engine);
            core_engine.renderer.drawImgui(World, &self.world, ctx);
            self.systems.drawImgui(&self.world, ctx);
            c.imgui.Render();
        }

        fn recordCommandBuffer(
            self: *@This(),
            core_engine: *Engine,
            frame: frames_mod.FrameData,
            image_idx: u32,
        ) void {
            var begin_info = vk.CommandBufferBeginInfo{
                .sType = vk.STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            };

            checkVk(vk.BeginCommandBuffer(frame.main_command_buffer, &begin_info)) catch @panic("failed to begin command buffer");
            defer checkVk(vk.EndCommandBuffer(frame.main_command_buffer)) catch @panic("failed to record command buffer");

            self.systems.recordComputeCommands(
                core_engine.allocated_resources,
                core_engine.renderer.swapchain,
                frame.main_command_buffer,
                image_idx,
            );

            const final_clear_value =
                vk.ClearValue{ .color = .{ .float32 = .{ 0, 0, 0, 1 } } };

            const attachment_clear_values = core.engine.Renderer.Attachments.clearValues().values;

            var all_clear_values: [@typeInfo(core.engine.Renderer.Attachments.Tags).@"enum".field_names.len + 1]vk.ClearValue = undefined;
            all_clear_values[0] = final_clear_value;
            @memcpy(all_clear_values[1..], &attachment_clear_values);

            var render_pass_info = vk.RenderPassBeginInfo{
                .sType = vk.STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
                .renderPass = core_engine.renderer.main_render_pass,
                .framebuffer = core_engine.renderer.swapchain.framebuffers[image_idx],
                .renderArea = .{
                    .offset = .{
                        .x = 0,
                        .y = 0,
                    },
                    .extent = vk.Extent2D{
                        .height = core_engine.renderer.swapchain.extent.height,
                        .width = core_engine.renderer.swapchain.extent.width,
                    },
                },
                .clearValueCount = all_clear_values.len,
                .pClearValues = &all_clear_values,
            };

            core_engine.renderer.swapchain.attachments.transitionAttachments(frame.main_command_buffer);
            vk.CmdBeginRenderPass(
                frame.main_command_buffer,
                &render_pass_info,
                vk.SUBPASS_CONTENTS_INLINE,
            );
            defer vk.CmdEndRenderPass(frame.main_command_buffer);

            const viewport = vk.Viewport{
                .x = 0,
                .y = 0,
                .width = @floatFromInt(core_engine.renderer.swapchain.extent.width),
                .height = @floatFromInt(core_engine.renderer.swapchain.extent.height),
                .minDepth = 0.0,
                .maxDepth = 1.0,
            };
            vk.CmdSetViewport(frame.main_command_buffer, 0, 1, &viewport);

            const scissor = vk.Rect2D{
                .offset = .{ .x = 0, .y = 0 },
                .extent = core_engine.renderer.swapchain.extent,
            };
            vk.CmdSetScissor(frame.main_command_buffer, 0, 1, &scissor);

            core_engine.renderer.recordCommands(&core_engine.renderer.swapchain, &core_engine.resources, &core_engine.allocated_resources, frame.main_command_buffer);
            c.imgui.impl_vulkan.RenderDrawData(c.imgui.GetDrawData(), frame.main_command_buffer);
        }

        fn drawFrame(self: *@This(), core_engine: *Engine) void {
            var frame = core_engine.frames.currentFrame();

            const present_semaphore = frame.render_semaphore;

            checkVk(vk.WaitForFences(core_engine.logical_device.handle, 1, &frame.render_fence, vk.TRUE, std.math.maxInt(u64))) catch @panic("failed to wait for current fence");

            // this feels like it should be in renderer
            var image_idx: u32 = undefined;
            checkVk(vk.AcquireNextImageKHR(core_engine.logical_device.handle, core_engine.renderer.swapchain.handle, std.math.maxInt(u64), present_semaphore, null, &image_idx)) catch |e|
                switch (e) {
                    VkError.ErrorOutOfDateKHR => {
                        core_engine.renderer.framebuffer_resized = true;
                    },
                    VkError.SuboptimalKHR => {},
                    else => @panic("failed to acquire next image"),
                };

            const submit_semaphore =
                core_engine.renderer.swapchain.render_semaphores[image_idx];

            checkVk(vk.ResetFences(core_engine.logical_device.handle, 1, &frame.render_fence)) catch @panic("failed to reset fences");
            checkVk(vk.ResetCommandBuffer(frame.main_command_buffer, 0)) catch @panic("failed to reset command buffers");

            self.recordCommandBuffer(core_engine, frame, image_idx);

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

            checkVk(vk.QueueSubmit(core_engine.logical_device.graphics_queue, 1, &submit_info, frame.render_fence)) catch @panic("failed to submit draw command buffer");

            const present_info = vk.PresentInfoKHR{
                .sType = vk.STRUCTURE_TYPE_PRESENT_INFO_KHR,
                .waitSemaphoreCount = 1,
                .pWaitSemaphores = signal_semaphores,
                .swapchainCount = 1,
                .pSwapchains = &[_]vk.SwapchainKHR{core_engine.renderer.swapchain.handle},
                .pImageIndices = &image_idx,
            };

            checkVk(vk.QueuePresentKHR(core_engine.logical_device.present_queue, &present_info)) catch |e| {
                if (e == VkError.ErrorOutOfDateKHR or
                    e == VkError.SuboptimalKHR or
                    core_engine.renderer.framebuffer_resized)
                {
                    core_engine.renderer.recreateSwapchain(core_engine.allocs, .{
                        .physical_device = core_engine.physical_device,
                        .logical_device = core_engine.logical_device.handle,
                        .surface = core_engine.surface,
                        .vsync = true,
                        .window = core_engine.window,
                        .alloc_cb = core_engine.alloc_cbs,
                    }, &core_engine.allocated_resources, core_engine.alloc_cbs);

                    self.systems.plexe.Debug.?.bindAttachments(
                        core_engine.allocs.std,
                        &core_engine.renderer.swapchain,
                        &core_engine.allocated_resources,
                    ) catch @panic("OOM");
                } else {
                    @panic("failed to present swapchain image");
                }
            };

            core_engine.frames.incrementFrame();
        }
    };
}

allocs: core.engine.Allocators,
alloc_cbs: ?*vk.AllocationCallbacks,
io: std.Io,

input: Input = .{},
window: *sdl.Window = undefined,
surface: vk.SurfaceKHR = undefined,
instance: vku.Instance = undefined,

physical_device: vku.PhysicalDevice = undefined,
logical_device: vku.LogicalDevice = undefined,
upload_context: vku.UploadContext = .{},

imgui_descriptor_pool: vk.DescriptorPool = undefined,

allocated_resources: core.resources.Manager.AllocatedData = undefined,
resources: core.resources.Manager = undefined,
physics: core.engine.Physics = undefined,
renderer: core.engine.Renderer = undefined,

frames: frames_mod.FramesContainer(MAX_FRAMES_IN_FLIGHT) = .{},

pub fn init(
    a: std.mem.Allocator,
    io: std.Io,
    resources_ci: core.resources.Manager.CreateInfo,
    /// TODO
    /// figure out a better pattern for configuring this
    camera_set_name: []const u8,
    alloc_cbs: ?*vk.AllocationCallbacks,
) Engine {
    var self = @This(){
        .allocs = .{ .std = a },
        .alloc_cbs = alloc_cbs,
        .io = io,
        // .world = core.engine.world.GameWorld.init(a) catch @panic("OOM"),
        .resources = core.resources.Manager.init(
            a,
            resources_ci,
        ) catch @panic("failed resources init"),
        .physics = core.engine.Physics.init(.{
            .allocator = a,
        }) catch @panic("OOM"),
    };

    self.initWindow();

    self.initVulkan();
    self.renderer = core.engine.Renderer.init(self.allocs, .{
        .meshes2D = true,
        .geometry = .{
            .camera_set_name = camera_set_name,
        },
        .physics_debug = if (self.physics.debug_ctx) |dbg|
            .{
                .ptr = dbg,
                .camera_set_name = camera_set_name,
            }
        else
            null,
        .swapchain = .{
            .physical_device = self.physical_device,
            .logical_device = self.logical_device.handle,
            .surface = self.surface,
            .old_swapchain = null,
            .vsync = true,
            .window = self.window,
            .alloc_cb = self.alloc_cbs,
        },
    }) catch @panic("OOM");

    self.renderer.createMainRenderPass(self.logical_device.handle, self.alloc_cbs);

    self.renderer.swapchain.createFramebuffers(
        self.allocs.std,
        self.logical_device.handle,
        self.renderer.main_render_pass,
        self.alloc_cbs,
    ) catch @panic("failed to create framebuffers");

    return self;
}

pub fn deinit(self: *Engine) void {
    checkVk(vk.DeviceWaitIdle(self.logical_device.handle)) catch @panic("Failed to wait for device idle");

    c.imgui.impl_vulkan.Shutdown();
    vk.DestroyDescriptorPool(self.logical_device.handle, self.imgui_descriptor_pool, self.alloc_cbs);

    self.resources.deinit(self.allocs.std, self.logical_device.handle, self.alloc_cbs);
    self.allocated_resources.deinit(self.allocs, self.logical_device.handle, self.alloc_cbs);

    self.physics.deinit(self.allocs.std);
    self.renderer.deinit(self.allocs, self.logical_device.handle, self.alloc_cbs);

    self.upload_context.deinit(self.logical_device.handle, self.alloc_cbs);
    self.frames.deinit(self.logical_device.handle, self.alloc_cbs);

    var stats: c.vma.TotalStatistics = undefined;
    c.vma.CalculateStatistics(self.allocs.vma, &stats);
    c.vma.DestroyAllocator(self.allocs.vma);

    vk.DestroyDevice(self.logical_device.handle, self.alloc_cbs);

    // Maybe instance should have it's own dei
    if (self.instance.debug_messenger != null) {
        const destroyFn = self.instance.getDestroyDebugUtilsMessengerFn() orelse @panic("Debug messenger present but there is no destroy function?")();
        destroyFn(self.instance.handle, self.instance.debug_messenger, self.alloc_cbs);
    }
    vk.DestroySurfaceKHR(self.instance.handle, self.surface, self.alloc_cbs);
    vk.DestroyInstance(self.instance.handle, self.alloc_cbs);

    sdl.DestroyWindow(self.window);

    sdl.Quit();
}

fn initWindow(self: *Engine) void {
    checkSdl(sdl.Init(sdl.INIT_VIDEO));
    const window = sdl.CreateWindow("Vulkan", INITIAL_WINDOW_EXTENT.width, INITIAL_WINDOW_EXTENT.height, sdl.WINDOW_VULKAN | sdl.WINDOW_RESIZABLE) orelse @panic("Failed to create SDL window");
    _ = sdl.SetWindowRelativeMouseMode(window, true);

    self.window = window;
}

fn initVulkan(self: *Engine) void {
    var sdl_required_extension_count: u32 = undefined;
    const sdl_extensions = sdl.Vulkan_GetInstanceExtensions(&sdl_required_extension_count);
    const sdl_extension_slice = sdl_extensions[0..sdl_required_extension_count];

    self.instance = vku.Instance.create(std.heap.page_allocator, .{
        .application_name = "VkGuide",
        .application_version = vk.MAKE_VERSION(0, 1, 0),
        .engine_name = "VkGuide",
        .engine_version = vk.MAKE_VERSION(0, 1, 0),
        .api_version = vk.MAKE_VERSION(1, 3, 0),
        .debug = true,
        .required_extensions = sdl_extension_slice,
    }) catch |err| {
        log.err("Failed to create vulkan instance with error: {s}", .{@errorName(err)});
        unreachable;
    };

    // surface creation
    checkSdl(sdl.Vulkan_CreateSurface(self.window, self.instance.handle, self.alloc_cbs, &self.surface));

    // Physical device creation
    const physical_device = vku.PhysicalDevice.select(self.allocs.std, self.instance.handle, .{
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

    var descriptor_indexing_features = vku.LogicalDevice.descriptorIndexingFeatures();
    descriptor_indexing_features.pNext = &shader_draw_parameters_features;

    const required_device_extensions: []const [*c]const u8 = &.{
        vk.KHR_SWAPCHAIN_EXTENSION_NAME,
        vk.KHR_SYNCHRONIZATION_2_EXTENSION_NAME,
        vk.KHR_DYNAMIC_RENDERING_EXTENSION_NAME,
        vk.KHR_DEPTH_STENCIL_RESOLVE_EXTENSION_NAME,
        vk.KHR_CREATE_RENDERPASS_2_EXTENSION_NAME,
        vk.KHR_PORTABILITY_SUBSET_EXTENSION_NAME,
    };
    const logical_device = vku.LogicalDevice.create(self.allocs.std, .{
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

    self.frames.initSyncObjects(self.logical_device.handle, self.alloc_cbs);
    self.upload_context.initSyncObjects(self.logical_device.handle, self.alloc_cbs);
    self.frames.initCommands(self.logical_device.handle, self.physical_device, self.alloc_cbs);
    self.upload_context.initCommands(self.logical_device.handle, self.physical_device, self.alloc_cbs);
}

pub fn uploadResources(self: *Engine) void {
    // BAD??
    const max_sets = 16;
    self.allocated_resources = self.resources.upload(
        self.allocs,
        max_sets,
        &self.upload_context,
        self.logical_device,
        self.alloc_cbs,
    ) catch @panic("OOM");
}

pub fn initImgui(self: *Engine) void {
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
        .Subpass = 2,
    };

    _ = c.imgui.impl_vulkan.Init(&init_info, self.renderer.main_render_pass);
    _ = c.imgui.impl_vulkan.CreateFontsTexture();
}
