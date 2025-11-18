const std = @import("std");
const root = @import("root.zig");
pub const c = @import("clibs.zig");
const vma_usage = @import("vma_usage.zig");
const vk = c.vk;
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.vulkan_init);
const Mat4 = @import("math3d.zig").Mat4;

pub const UploadContext = struct {
    upload_fence: c.vk.Fence = null,
    command_pool: c.vk.CommandPool = null,
    command_buffer: c.vk.CommandBuffer = null,

    pub fn immediateSubmit(self: *@This(), device: LogicalDevice, submit_ctx: anytype) void {
        // Check the context is good
        comptime {
            var Context = @TypeOf(submit_ctx);
            var is_ptr = false;
            switch (@typeInfo(Context)) {
                .@"struct", .@"union", .@"enum" => {},
                .pointer => |ptr| {
                    if (ptr.size != .one) {
                        @compileError("Context must be a type with a submit function. " ++ @typeName(Context) ++ "is a multi element pointer");
                    }
                    Context = ptr.child;
                    is_ptr = true;
                    switch (Context) {
                        .Struct, .Union, .Enum, .Opaque => {},
                        else => @compileError("Context must be a type with a submit function. " ++ @typeName(Context) ++ "is a pointer to a non struct/union/enum/opaque type"),
                    }
                },
                else => @compileError("Context must be a type with a submit method. Cannot use: " ++ @typeName(Context)),
            }

            if (!@hasDecl(Context, "submit")) {
                @compileError("Context should have a PUBLIC submit method");
            }

            const submit_fn_info = @typeInfo(@TypeOf(Context.submit));
            if (submit_fn_info != .@"fn") {
                @compileError("Context submit method should be a function");
            }

            if (submit_fn_info.@"fn".params.len != 2) {
                @compileError("Context submit method should have two parameters");
            }

            if (submit_fn_info.@"fn".params[0].type != Context) {
                @compileError("Context submit method first parameter should be of type: " ++ @typeName(Context));
            }

            if (submit_fn_info.@"fn".params[1].type != c.vk.CommandBuffer) {
                @compileError("Context submit method second parameter should be of type: " ++ @typeName(c.vk.CommandBuffer));
            }
        }

        const cmd = self.command_buffer;

        const commmand_begin_ci = c.vk.CommandBufferBeginInfo{
            .sType = c.vk.STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.vk.COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        };
        checkVk(c.vk.BeginCommandBuffer(cmd, &commmand_begin_ci)) catch @panic("Failed to begin command buffer");

        submit_ctx.submit(cmd);

        checkVk(c.vk.EndCommandBuffer(cmd)) catch @panic("Failed to end command buffer");

        const submit_info = std.mem.zeroInit(c.vk.SubmitInfo, .{
            .sType = c.vk.STRUCTURE_TYPE_SUBMIT_INFO,
            .commandBufferCount = 1,
            .pCommandBuffers = &cmd,
        });

        checkVk(c.vk.QueueSubmit(device.graphics_queue, 1, &submit_info, self.upload_fence)) catch @panic("Failed to submit to graphics queue");

        checkVk(c.vk.WaitForFences(device.handle, 1, &self.upload_fence, c.vk.TRUE, 1_000_000_000)) catch @panic("Failed to wait for upload fence");
        checkVk(c.vk.ResetFences(device.handle, 1, &self.upload_fence)) catch @panic("Failed to reset upload fence");

        checkVk(c.vk.ResetCommandPool(device.handle, self.command_pool, 0)) catch @panic("Failed to reset command pool");
    }
};

pub const GPUCameraData = struct {
    model: Mat4,
    view: Mat4,
    proj: Mat4,
};

pub const FrameData = struct {
    present_semaphore: c.vk.Semaphore = null,
    render_fence: c.vk.Fence = null,
    command_pool: c.vk.CommandPool = null,
    main_command_buffer: c.vk.CommandBuffer = null,

    camera_data: root.vma_usage.AllocatedBuffer = .{ .buffer = null, .allocation = null },
    camera_data_mapped: ?*anyopaque = undefined,
    camera_data_descriptor_set: c.vk.DescriptorSet = null,

    const Self = @This();

    pub fn deinit(self: *Self, vma_a: c.vma.Allocator, device: c.vk.Device, vk_alloc_cbs: ?*c.vk.AllocationCallbacks) void {
        vk.DestroySemaphore(device, self.present_semaphore, vk_alloc_cbs);
        vk.DestroyFence(device, self.render_fence, vk_alloc_cbs);
        vk.DestroyCommandPool(device, self.command_pool, vk_alloc_cbs);

        c.vma.UnmapMemory(vma_a, self.camera_data.allocation);
        c.vma.DestroyBuffer(vma_a, self.camera_data.buffer, self.camera_data.allocation);
    }

    pub fn initSyncObjects(self: *Self, device: c.vk.Device, vk_alloc_cbs: ?*c.vk.AllocationCallbacks) void {
        const semaphore_ci = vk.SemaphoreCreateInfo{
            .sType = vk.STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        };

        const fence_ci = vk.FenceCreateInfo{
            .sType = vk.STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .flags = vk.FENCE_CREATE_SIGNALED_BIT,
        };

        checkVk(c.vk.CreateSemaphore(device, &semaphore_ci, vk_alloc_cbs, &self.present_semaphore)) catch @panic("failed to create semaphore");

        checkVk(c.vk.CreateFence(device, &fence_ci, vk_alloc_cbs, &self.render_fence)) catch @panic("failed to create render fence");
    }

    pub fn initBuffers(self: *Self, vma_a: c.vma.Allocator) void {
        const buf_size = @sizeOf(GPUCameraData);
        self.camera_data = vma_usage.AllocatedBuffer.create(
            vma_a,
            buf_size,
            vk.BUFFER_USAGE_UNIFORM_BUFFER_BIT,
            c.vma.MEMORY_USAGE_CPU_TO_GPU,
        );
        checkVk(c.vma.MapMemory(vma_a, self.camera_data.allocation, &self.camera_data_mapped)) catch @panic("failed to map uniform buffer");
    }

    pub fn initCommands(self: *Self, device: vk.Device, phys_device: PhysicalDevice, vk_alloc_cbs: ?*vk.AllocationCallbacks) void {
        const command_pool_ci = vk.CommandPoolCreateInfo{
            .sType = vk.STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = vk.COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = phys_device.graphics_queue_family,
        };

        checkVk(vk.CreateCommandPool(device, &command_pool_ci, vk_alloc_cbs, &self.command_pool)) catch log.err("Failed to create command pool", .{});
        // Allocate a command buffer from the command pool
        const command_buffer_ai = vk.CommandBufferAllocateInfo{
            .sType = vk.STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = self.command_pool,
            .level = vk.COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };

        checkVk(vk.AllocateCommandBuffers(device, &command_buffer_ai, &self.main_command_buffer)) catch @panic("Failed to allocate command buffer");
    }

    pub fn initDescriptorSets(
        self: *Self,
        device: vk.Device,
        pool: vk.DescriptorPool,
        layout: vk.DescriptorSetLayout,
        texture_image_view: vk.ImageView,
        texture_sampler: vk.Sampler,
    ) void {
        const ai = vk.DescriptorSetAllocateInfo{
            .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .descriptorPool = pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &layout,
        };
        checkVk(vk.AllocateDescriptorSets(device, &ai, &self.camera_data_descriptor_set)) catch @panic("failed to allocate descriptor sets");

        const camera_data_info = vk.DescriptorBufferInfo{
            .buffer = self.camera_data.buffer,
            .offset = 0,
            .range = @sizeOf(GPUCameraData),
        };

        const camera_data_write = vk.WriteDescriptorSet{
            .dstBinding = 0,
            .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = self.camera_data_descriptor_set,
            .dstArrayElement = 0,
            .descriptorType = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
            .descriptorCount = 1,
            .pBufferInfo = &camera_data_info,
        };

        const img_info = vk.DescriptorImageInfo{
            .imageLayout = vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
            .imageView = texture_image_view,
            .sampler = texture_sampler,
        };

        const img_write = vk.WriteDescriptorSet{
            .dstBinding = 1,
            .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = self.camera_data_descriptor_set,
            .dstArrayElement = 0,
            .descriptorType = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .descriptorCount = 1,
            .pImageInfo = &img_info,
        };

        const writes = &[_]vk.WriteDescriptorSet{ camera_data_write, img_write };

        vk.UpdateDescriptorSets(device, writes.len, writes, 0, null);
    }
};

/// Contains the instance and an optional debug messenger, if
/// Options.debug was true and the validation layer was available.
pub const Instance = struct {
    handle: vk.Instance = null,
    debug_messenger: vk.DebugUtilsMessengerEXT = null,

    /// Instance initialisation settings.
    ///
    pub const Options = struct {
        application_name: [:0]const u8 = "vki",
        application_version: u32 = vk.MAKE_VERSION(1, 0, 0),
        engine_name: ?[:0]const u8 = null,
        engine_version: u32 = vk.MAKE_VERSION(1, 0, 0),
        api_version: u32 = vk.MAKE_VERSION(1, 0, 0),
        debug: bool = false,
        debug_callback: vk.PFN_DebugUtilsMessengerCallbackEXT = null,
        required_extensions: []const [*c]const u8 = &.{},
        alloc_cb: ?*vk.AllocationCallbacks = null,
    };

    /// Create a vulkan instance and otpional debug functionalities.
    ///
    /// # Allocations
    ///
    /// Initialization code does not require persistent allocations.
    /// All the allocation are automatically cleared when the function returns.
    pub fn create(alloc: Allocator, opts: Options) !@This() {
        // Check the api version is supported
        if (opts.api_version > vk.MAKE_VERSION(1, 0, 0)) {
            var api_requested = opts.api_version;
            try checkVk(vk.EnumerateInstanceVersion(@ptrCast(&api_requested)));
        }

        var enable_validation = opts.debug;

        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // Get supported layers and extensions
        var layer_count: u32 = undefined;
        try checkVk(vk.EnumerateInstanceLayerProperties(&layer_count, null));
        const layer_props = try arena.alloc(vk.LayerProperties, layer_count);
        try checkVk(vk.EnumerateInstanceLayerProperties(&layer_count, layer_props.ptr));

        var extension_count: u32 = undefined;
        try checkVk(vk.EnumerateInstanceExtensionProperties(null, &extension_count, null));
        const extension_props = try arena.alloc(vk.ExtensionProperties, extension_count);
        try checkVk(vk.EnumerateInstanceExtensionProperties(null, &extension_count, extension_props.ptr));

        // Check if the validation layer is supported
        var layers = std.ArrayListUnmanaged([*c]const u8){};
        if (enable_validation) {
            enable_validation = blk: for (layer_props) |layer_prop| {
                const layer_name: [*c]const u8 = @ptrCast(layer_prop.layerName[0..]);
                const validation_layer_name: [*c]const u8 = "VK_LAYER_KHRONOS_validation";
                if (std.mem.eql(u8, std.mem.span(validation_layer_name), std.mem.span(layer_name))) {
                    try layers.append(arena, validation_layer_name);
                    break :blk true;
                }
            } else false;
        }

        // Check if the required extensions are supported
        var extensions = std.ArrayListUnmanaged([*c]const u8){};

        const ExtensionFinder = struct {
            fn find(name: [*c]const u8, props: []vk.ExtensionProperties) bool {
                for (props) |prop| {
                    const prop_name: [*c]const u8 = @ptrCast(prop.extensionName[0..]);
                    if (std.mem.eql(u8, std.mem.span(name), std.mem.span(prop_name))) {
                        return true;
                    }
                }
                return false;
            }
        };

        // Start ensuring all SDL required extensions are supported
        for (opts.required_extensions) |required_ext| {
            if (ExtensionFinder.find(required_ext, extension_props)) {
                try extensions.append(arena, required_ext);
            } else {
                log.err("Required vulkan extension not supported: {s}", .{required_ext});
                return error.VulkanExtensionNotSupported;
            }
        }

        // Add extensions required to run on Mac with MoltenVK
        // https://stackoverflow.com/questions/58732459/vk-error-incompatible-driver-with-mac-os-and-vulkan-moltenvk
        // https://docs.vulkan.org/guide/latest/enabling_extensions.html
        try extensions.append(arena, vk.KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME);
        try extensions.append(arena, vk.KHR_GET_PHYSICAL_DEVICE_PROPERTIES_2_EXTENSION_NAME);
        // FOR DEVICE!
        // try extensions.append(arena, vk.KHR_PORTABILITY_SUBSET_EXTENSION_NAME);

        // If we need validation, also add the debug utils extension
        if (enable_validation and ExtensionFinder.find("VK_EXT_debug_utils", extension_props)) {
            try extensions.append(arena, "VK_EXT_debug_utils");
        } else {
            enable_validation = false;
        }

        const app_info = std.mem.zeroInit(vk.ApplicationInfo, .{
            .sType = vk.STRUCTURE_TYPE_APPLICATION_INFO,
            .apiVersion = opts.api_version,
            .pApplicationName = opts.application_name,
            .pEngineName = opts.engine_name orelse opts.application_name,
        });

        log.info(
            \\ Creating Instance with extensions:
        , .{});
        for (extensions.items) |i| {
            log.info(
                \\ {s}
            , .{i});
        }

        const instance_info = std.mem.zeroInit(vk.InstanceCreateInfo, .{
            .flags = vk.INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR,
            .sType = vk.STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &app_info,
            .enabledLayerCount = @as(u32, @intCast(layers.items.len)),
            .ppEnabledLayerNames = layers.items.ptr,
            .enabledExtensionCount = @as(u32, @intCast(extensions.items.len)),
            .ppEnabledExtensionNames = extensions.items.ptr,
        });

        var instance: vk.Instance = undefined;
        try checkVk(vk.CreateInstance(&instance_info, opts.alloc_cb, &instance));
        log.info("Created vulkan instance.", .{});

        // Create the debug messenger if needed
        const debug_messenger = if (enable_validation)
            try createDebugCallback(instance, opts)
        else
            null;

        return .{ .handle = instance, .debug_messenger = debug_messenger };
    }

    pub fn getDestroyDebugUtilsMessengerFn(self: @This()) vk.PFN_DestroyDebugUtilsMessengerEXT {
        return getVulkanInstanceFunct(vk.PFN_DestroyDebugUtilsMessengerEXT, self.handle, "vkDestroyDebugUtilsMessengerEXT");
    }

    fn getVulkanInstanceFunct(comptime Fn: type, instance: vk.Instance, name: [*c]const u8) Fn {
        const get_proc_addr: vk.PFN_GetInstanceProcAddr = @ptrCast(c.sdl.Vulkan_GetVkGetInstanceProcAddr());
        if (get_proc_addr) |get_proc_addr_fn| {
            return @ptrCast(get_proc_addr_fn(instance, name));
        }

        @panic("SDL_Vulkan_GetVkGetInstanceProcAddr returned null");
    }

    fn createDebugCallback(instance: vk.Instance, opts: Options) !vk.DebugUtilsMessengerEXT {
        const create_fn_opt = getVulkanInstanceFunct(vk.PFN_CreateDebugUtilsMessengerEXT, instance, "vkCreateDebugUtilsMessengerEXT");
        if (create_fn_opt) |create_fn| {
            const create_info = std.mem.zeroInit(vk.DebugUtilsMessengerCreateInfoEXT, .{
                .sType = vk.STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
                .messageSeverity = vk.DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT |
                    vk.DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                    vk.DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
                .messageType = vk.DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                    vk.DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                    vk.DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
                .pfnUserCallback = opts.debug_callback orelse defaultDebugCallback,
                .pUserData = null,
            });
            var debug_messenger: vk.DebugUtilsMessengerEXT = undefined;
            try checkVk(create_fn(instance, &create_info, opts.alloc_cb, &debug_messenger));
            log.info("Created vulkan debug messenger.", .{});
            return debug_messenger;
        }
        return null;
    }

    fn defaultDebugCallback(severity: vk.DebugUtilsMessageSeverityFlagBitsEXT, msg_type: vk.DebugUtilsMessageTypeFlagsEXT, callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT, user_data: ?*anyopaque) callconv(.c) vk.Bool32 {
        _ = user_data;
        const severity_str = switch (severity) {
            vk.DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT => "verbose",
            vk.DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT => "info",
            vk.DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT => "warning",
            vk.DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT => "error",
            else => "unknown",
        };

        const type_str = switch (msg_type) {
            vk.DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT => "general",
            vk.DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT => "validation",
            vk.DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT => "performance",
            else => "unknown",
        };

        const message: [*c]const u8 = if (callback_data) |cb_data| cb_data.pMessage else "NO MESSAGE!";
        log.err("[{s}][{s}]. Message:\n  {s}", .{ severity_str, type_str, message });

        if (severity >= vk.DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT) {
            @panic("Unrecoverable vulkan error.");
        }

        return vk.FALSE;
    }
};

/// Selection criteria for a physical device.
///
pub const PhysicalDeviceSelectionCriteria = enum {
    /// Select the first device that matches the criteria.
    First,
    /// Prefer a discrete gpu.
    PreferDiscrete,
};

/// Result of a call to select_physical_device.
///
pub const PhysicalDevice = struct {
    /// The selected physical device.
    handle: vk.PhysicalDevice = null,
    /// The selected physical device properties.
    properties: vk.PhysicalDeviceProperties = undefined,
    /// Queue family indices.
    graphics_queue_family: u32 = undefined,
    present_queue_family: u32 = undefined,
    compute_queue_family: u32 = undefined,
    transfer_queue_family: u32 = undefined,

    const INVALID_QUEUE_FAMILY_INDEX = std.math.maxInt(u32);

    /// Device selector options
    ///
    pub const SelectOpts = struct {
        /// Minimum required vulkan api version.
        min_api_version: u32 = vk.MAKE_VERSION(1, 0, 0),
        /// Required device extensions.
        required_extensions: []const [*c]const u8 = &.{},
        /// Presentation surface.
        surface: vk.SurfaceKHR,
        /// Selection criteria.
        criteria: PhysicalDeviceSelectionCriteria = .PreferDiscrete,
    };

    /// Find suitable physical device.
    ///
    /// # Allocations
    /// This function does not require persistent allocations.
    ///
    pub fn select(a: Allocator, instance: vk.Instance, opts: SelectOpts) !PhysicalDevice {
        var physical_device_count: u32 = undefined;
        try checkVk(vk.EnumeratePhysicalDevices(instance, &physical_device_count, null));

        var arena_state = std.heap.ArenaAllocator.init(a);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const physical_devices = try arena.alloc(vk.PhysicalDevice, physical_device_count);
        try checkVk(vk.EnumeratePhysicalDevices(instance, &physical_device_count, physical_devices.ptr));

        var suitable_pd: ?PhysicalDevice = null;

        for (physical_devices) |device| {
            const pd = make(a, device, opts.surface) catch continue;
            _ = pd.isSuitable(a, opts) catch continue;

            if (opts.criteria == PhysicalDeviceSelectionCriteria.First) {
                suitable_pd = pd;
                break;
            }

            if (pd.properties.deviceType == vk.PHYSICAL_DEVICE_TYPE_DISCRETE_GPU) {
                suitable_pd = pd;
                break;
            } else if (suitable_pd == null) {
                suitable_pd = pd;
            }
        }

        if (suitable_pd == null) {
            log.err("No suitable physical device found.", .{});
            return error.VulkanNoSuitablePhysicalDevice;
        }
        const res = suitable_pd.?;

        const device_name = @as([*:0]const u8, @ptrCast(@alignCast(res.properties.deviceName[0..])));
        log.info("Selected physical device: {s}", .{device_name});

        return res;
    }

    pub fn findSupportedFormat(self: @This(), candidates: []const vk.Format, tiling: vk.ImageTiling, features: vk.FormatFeatureFlags) !vk.Format {
        for (0..candidates.len) |i| {
            var props: vk.FormatProperties = undefined;
            vk.GetPhysicalDeviceFormatProperties(self.handle, candidates[i], &props);
            if ((tiling == vk.IMAGE_TILING_LINEAR and (props.linearTilingFeatures & features) == features)
            //
            or (tiling == vk.IMAGE_TILING_OPTIMAL and (props.optimalTilingFeatures & features) == features)) {
                return candidates[i];
            }
        }
        return error.FailedFindingSupportedFormat;
    }

    fn make(a: Allocator, device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !@This() {
        var props = std.mem.zeroInit(vk.PhysicalDeviceProperties, .{});
        vk.GetPhysicalDeviceProperties(device, &props);

        var graphics_queue_family: u32 = PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX;
        var present_queue_family: u32 = PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX;
        var compute_queue_family: u32 = PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX;
        var transfer_queue_family: u32 = PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX;

        var queue_family_count: u32 = undefined;
        vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);
        const queue_families = try a.alloc(vk.QueueFamilyProperties, queue_family_count);
        defer a.free(queue_families);
        vk.GetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, queue_families.ptr);

        for (queue_families, 0..) |queue_family, i| {
            const index: u32 = @intCast(i);

            if (graphics_queue_family == PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX and
                queue_family.queueFlags & vk.QUEUE_GRAPHICS_BIT != 0)
            {
                graphics_queue_family = index;
            }

            if (present_queue_family == PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX) {
                var present_support: vk.Bool32 = undefined;
                try checkVk(vk.GetPhysicalDeviceSurfaceSupportKHR(device, index, surface, &present_support));
                if (present_support == vk.TRUE) {
                    present_queue_family = index;
                }
            }

            if (compute_queue_family == PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX and
                queue_family.queueFlags & vk.QUEUE_COMPUTE_BIT != 0)
            {
                compute_queue_family = index;
            }

            if (transfer_queue_family == PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX and
                queue_family.queueFlags & vk.QUEUE_TRANSFER_BIT != 0)
            {
                transfer_queue_family = index;
            }

            if (graphics_queue_family != PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX and
                present_queue_family != PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX and
                compute_queue_family != PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX and
                transfer_queue_family != PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX)
            {
                break;
            }
        }

        return .{
            .handle = device,
            .properties = props,
            .graphics_queue_family = graphics_queue_family,
            .present_queue_family = present_queue_family,
            .compute_queue_family = compute_queue_family,
            .transfer_queue_family = transfer_queue_family,
        };
    }

    fn isSuitable(self: @This(), a: Allocator, opts: SelectOpts) !bool {
        if (self.properties.apiVersion < opts.min_api_version) {
            return false;
        }

        if (self.graphics_queue_family == PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX or
            self.present_queue_family == PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX or
            self.compute_queue_family == PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX or
            self.transfer_queue_family == PhysicalDevice.INVALID_QUEUE_FAMILY_INDEX)
        {
            return false;
        }

        var arena_state = std.heap.ArenaAllocator.init(a);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const swapchain_support = try SwapchainSupportInfo.init(arena, self.handle, opts.surface);
        defer swapchain_support.deinit(arena);
        if (swapchain_support.formats.len == 0 or swapchain_support.present_modes.len == 0) {
            return false;
        }

        if (opts.required_extensions.len > 0) {
            var device_extension_count: u32 = undefined;
            try checkVk(vk.EnumerateDeviceExtensionProperties(self.handle, null, &device_extension_count, null));
            const device_extensions = try arena.alloc(vk.ExtensionProperties, device_extension_count);
            try checkVk(vk.EnumerateDeviceExtensionProperties(self.handle, null, &device_extension_count, device_extensions.ptr));

            _ = blk: for (opts.required_extensions) |req_ext| {
                for (device_extensions) |device_ext| {
                    const device_ext_name: [*c]const u8 = @ptrCast(device_ext.extensionName[0..]);
                    if (std.mem.eql(u8, std.mem.span(req_ext), std.mem.span(device_ext_name))) {
                        break :blk true;
                    }
                }
            } else return false;
        }

        return true;
    }
};

/// Options for creating a logical device.
///
const DeviceCreateOpts = struct {
    /// The physical device.
    physical_device: PhysicalDevice,
    /// The logical device features.
    features: vk.PhysicalDeviceFeatures = undefined,
    /// The logical device allocation callbacks.
    alloc_cb: ?*const vk.AllocationCallbacks = null,
    /// Optional pnext chain for VkDeviceCreateInfo.
    pnext: ?*const anyopaque = null,
};

/// Result from the creation of a logical device.
///
pub const LogicalDevice = struct {
    handle: vk.Device = null,
    graphics_queue: vk.Queue = null,
    present_queue: vk.Queue = null,
    compute_queue: vk.Queue = null,
    transfer_queue: vk.Queue = null,

    /// Create logical device
    ///
    /// # Allocations
    /// This function does not require persistent allocations.
    pub fn create(a: Allocator, opts: DeviceCreateOpts) !LogicalDevice {
        var arena_state = std.heap.ArenaAllocator.init(a);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var queue_create_infos = std.ArrayListUnmanaged(vk.DeviceQueueCreateInfo){};
        const queue_priorities: f32 = 1.0;

        var queue_family_set = std.AutoArrayHashMapUnmanaged(u32, void){};
        try queue_family_set.put(arena, opts.physical_device.graphics_queue_family, {});
        try queue_family_set.put(arena, opts.physical_device.present_queue_family, {});
        try queue_family_set.put(arena, opts.physical_device.compute_queue_family, {});
        try queue_family_set.put(arena, opts.physical_device.transfer_queue_family, {});

        var qfi_iter = queue_family_set.iterator();
        try queue_create_infos.ensureTotalCapacity(arena, queue_family_set.count());
        while (qfi_iter.next()) |qfi| {
            try queue_create_infos.append(arena, vk.DeviceQueueCreateInfo{
                .sType = vk.STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .queueFamilyIndex = qfi.key_ptr.*,
                .queueCount = 1,
                .pQueuePriorities = &queue_priorities,
            });
        }

        const device_extensions: []const [*c]const u8 = &.{
            "VK_KHR_swapchain",
            // for Mac
            vk.KHR_PORTABILITY_SUBSET_EXTENSION_NAME,
        };

        const device_info = vk.DeviceCreateInfo{
            .sType = vk.STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = opts.pnext,
            .queueCreateInfoCount = @as(u32, @intCast(queue_create_infos.items.len)),
            .pQueueCreateInfos = queue_create_infos.items.ptr,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = @as(u32, @intCast(device_extensions.len)),
            .ppEnabledExtensionNames = device_extensions.ptr,
            .pEnabledFeatures = &opts.features,
        };

        var device: vk.Device = undefined;
        try checkVk(vk.CreateDevice(opts.physical_device.handle, &device_info, opts.alloc_cb, &device));

        var graphics_queue: vk.Queue = undefined;
        vk.GetDeviceQueue(device, opts.physical_device.graphics_queue_family, 0, &graphics_queue);
        var present_queue: vk.Queue = undefined;
        vk.GetDeviceQueue(device, opts.physical_device.present_queue_family, 0, &present_queue);
        var compute_queue: vk.Queue = undefined;
        vk.GetDeviceQueue(device, opts.physical_device.compute_queue_family, 0, &compute_queue);
        var transfer_queue: vk.Queue = undefined;
        vk.GetDeviceQueue(device, opts.physical_device.transfer_queue_family, 0, &transfer_queue);

        return .{
            .handle = device,
            .graphics_queue = graphics_queue,
            .present_queue = present_queue,
            .compute_queue = compute_queue,
            .transfer_queue = transfer_queue,
        };
    }
};

pub const DepthResource = struct {
    allocation: vma_usage.AllocatedImage,
    view: vk.ImageView,

    pub fn findDepthFormat(device: PhysicalDevice) vk.Format {
        return device.findSupportedFormat(
            &[_]vk.Format{ vk.FORMAT_D32_SFLOAT, vk.FORMAT_D32_SFLOAT_S8_UINT, vk.FORMAT_D24_UNORM_S8_UINT },
            vk.IMAGE_TILING_OPTIMAL,
            vk.FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT,
        ) catch @panic("failed to find depth format");
    }

    pub fn init(
        vma_a: c.vma.Allocator,
        physical_device: PhysicalDevice,
        logical_device: vk.Device,
        swapchain_extent: vk.Extent2D,
        vk_alloc_cbs: ?*vk.AllocationCallbacks,
    ) @This() {
        const depth_format = findDepthFormat(physical_device);
        var allocation: vma_usage.AllocatedImage = undefined;
        var image_view: vk.ImageView = undefined;

        const ci = vk.ImageCreateInfo{
            .sType = vk.STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .imageType = vk.IMAGE_TYPE_2D,
            .format = depth_format,
            .extent = vk.Extent3D{
                .depth = 1,
                .height = swapchain_extent.height,
                .width = swapchain_extent.width,
            },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = vk.SAMPLE_COUNT_1_BIT,
            .tiling = vk.IMAGE_TILING_OPTIMAL,
            .usage = vk.IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
            .sharingMode = vk.SHARING_MODE_EXCLUSIVE,
            .initialLayout = vk.IMAGE_LAYOUT_UNDEFINED,
        };

        const ai = c.vma.AllocationCreateInfo{
            .usage = c.vma.MEMORY_USAGE_GPU_ONLY,
            .requiredFlags = vk.MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        };

        checkVk(c.vma.CreateImage(
            vma_a,
            &ci,
            &ai,
            &allocation.image,
            &allocation.allocation,
            null,
        )) catch @panic("failed to create image");

        const depth_image_view_ci = vk.ImageViewCreateInfo{
            .sType = vk.STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .image = allocation.image,
            .viewType = vk.IMAGE_VIEW_TYPE_2D,
            .format = depth_format,
            .subresourceRange = .{
                .aspectMask = vk.IMAGE_ASPECT_DEPTH_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1,
            },
        };

        checkVk(vk.CreateImageView(
            logical_device,
            &depth_image_view_ci,
            vk_alloc_cbs,
            &image_view,
        )) catch @panic("Failed to create depth image view");

        // apparently redundant because this is done in the render pass
        // texs.transitionImageLayout(
        //     &self.upload_context,
        //     self.logical_device,
        //     self.depth_image.image,
        //     depth_format,
        //     vk.IMAGE_LAYOUT_UNDEFINED,
        //     vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
        // );
        return @This(){
            .allocation = allocation,
            .view = image_view,
        };
    }

    pub fn deinit(
        self: @This(),
        vma_a: c.vma.Allocator,
        device: vk.Device,
        vk_alloc_cbs: ?*vk.AllocationCallbacks,
    ) void {
        vk.DestroyImageView(device, self.view, vk_alloc_cbs);
        c.vma.DestroyImage(vma_a, self.allocation.image, self.allocation.allocation);
    }
};

/// Options for creating a swapchain.
pub const SwapchainCreateOpts = struct {
    physical_device: PhysicalDevice,
    logical_device: vk.Device,
    surface: vk.SurfaceKHR,
    old_swapchain: vk.SwapchainKHR = null,
    vsync: bool = false,
    triple_buffer: bool = false,
    window_width: u32 = 0,
    window_height: u32 = 0,
    alloc_cb: ?*vk.AllocationCallbacks = null,
    depth_buffer: bool,
};

/// Swapchain.
/// Creation needs to be done through init.
pub const Swapchain = struct {
    handle: vk.SwapchainKHR = null,
    images: []vk.Image = &.{},
    /// one finish semaphore per swapchain image
    render_semaphores: []c.vk.Semaphore = &.{},
    image_views: []vk.ImageView = &.{},
    framebuffers: []vk.Framebuffer = &.{},
    format: vk.Format = undefined,
    extent: vk.Extent2D = undefined,
    depth_resource: ?DepthResource = null,

    pub fn create(a: Allocator, vma_a: c.vma.Allocator, opts: SwapchainCreateOpts) !@This() {
        const support_info = try SwapchainSupportInfo.init(a, opts.physical_device.handle, opts.surface);
        defer support_info.deinit(a);

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
            .imageUsage = vk.IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
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
        const swapchain_images = try a.alloc(vk.Image, swapchain_image_count);
        errdefer a.free(swapchain_images);
        try checkVk(vk.GetSwapchainImagesKHR(opts.logical_device, swapchain, &swapchain_image_count, swapchain_images.ptr));

        // Create image views for the swapchain images.
        const swapchain_image_views = try a.alloc(vk.ImageView, swapchain_image_count);
        errdefer a.free(swapchain_image_views);

        for (swapchain_images, swapchain_image_views) |image, *view| {
            view.* = try createImageView(opts.logical_device, image, format, vk.IMAGE_ASPECT_COLOR_BIT, opts.alloc_cb);
        }

        const semaphore_ci = vk.SemaphoreCreateInfo{
            .sType = vk.STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        };
        const semaphores = a.alloc(c.vk.Semaphore, swapchain_image_count) catch @panic("Out of memory");
        errdefer a.free(semaphores);

        for (0..semaphores.len) |i| {
            checkVk(c.vk.CreateSemaphore(opts.logical_device, &semaphore_ci, opts.alloc_cb, &semaphores[i])) catch @panic("failed to create semaphore");
        }

        const depth_resource = if (opts.depth_buffer)
            DepthResource.init(vma_a, opts.physical_device, opts.logical_device, extent, opts.alloc_cb)
        else
            null;

        return .{
            .handle = swapchain,
            .images = swapchain_images,
            .render_semaphores = semaphores,
            .image_views = swapchain_image_views,
            .format = format,
            .extent = extent,
            .depth_resource = depth_resource,
        };
    }

    pub fn deinit(self: *@This(), a: Allocator, vma_a: c.vma.Allocator, device: vk.Device, vk_alloc_cbs: ?*vk.AllocationCallbacks) void {
        for (self.framebuffers) |fb| {
            vk.DestroyFramebuffer(device, fb, vk_alloc_cbs);
        }

        for (self.image_views) |iv| {
            vk.DestroyImageView(device, iv, vk_alloc_cbs);
        }

        for (0..self.render_semaphores.len) |k| {
            vk.DestroySemaphore(device, self.render_semaphores[k], vk_alloc_cbs);
        }

        if (self.depth_resource) |b| {
            b.deinit(vma_a, device, vk_alloc_cbs);
        }

        a.free(self.images);
        a.free(self.image_views);
        a.free(self.framebuffers);
        a.free(self.render_semaphores);

        vk.DestroySwapchainKHR(device, self.handle, vk_alloc_cbs);
    }

    pub fn recreate(self: *@This(), a: Allocator, vma_a: c.vma.Allocator, opts: SwapchainCreateOpts, window: *c.sdl.Window, render_pass: vk.RenderPass, vk_alloc_cbs: ?*vk.AllocationCallbacks) void {
        log.warn(
            \\ Recreating Swapchain!
            \\
        , .{});
        var width: c_int, var height: c_int = .{ undefined, undefined };
        root.checkSdl(c.sdl.GetWindowSize(window, &width, &height));
        while (width == 0 or height == 0) {
            root.checkSdl(c.sdl.GetWindowSize(window, &width, &height));
        }
        _ = vk.DeviceWaitIdle(opts.logical_device);

        // maybe this fn should take a ptr to opts?
        // opts.window_height = height;
        // opts.window_width = width;

        // opts.old_swapchain = self.handle;

        const new_swapchain = Swapchain.create(a, vma_a, opts) catch @panic("failed to create swapchain in recreate fn!");
        self.deinit(a, vma_a, opts.logical_device, vk_alloc_cbs);
        self.* = new_swapchain;
        // self.createImageViews();
        self.createFramebuffers(
            a,
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
            const attachments = &if (self.depth_resource) |r|
                [_]vk.ImageView{ self.image_views[i], r.view }
            else
                [_]vk.ImageView{self.image_views[i]};

            const ci = vk.FramebufferCreateInfo{
                .sType = vk.STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                .renderPass = render_pass,
                .attachmentCount = @as(u32, @intCast(attachments.len)),
                .pAttachments = attachments.ptr,
                .width = self.extent.width,
                .height = self.extent.height,
                .layers = 1,
            };
            checkVk(vk.CreateFramebuffer(device, &ci, vk_alloc_cbs, &framebuffers[i])) catch @panic("failed to create framebuffer");
        }

        self.framebuffers = framebuffers;
    }

    fn createImageView(device: vk.Device, image: vk.Image, format: vk.Format, aspect_flags: vk.ImageAspectFlags, alloc_cb: ?*vk.AllocationCallbacks) !vk.ImageView {
        const view_info = std.mem.zeroInit(vk.ImageViewCreateInfo, .{
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
        });

        var image_view: vk.ImageView = undefined;
        try checkVk(vk.CreateImageView(device, &view_info, alloc_cb, &image_view));
        return image_view;
    }
};

const SwapchainSupportInfo = struct {
    capabilities: vk.SurfaceCapabilitiesKHR = undefined,
    formats: []vk.SurfaceFormatKHR = &.{},
    present_modes: []vk.PresentModeKHR = &.{},

    const Self = @This();

    fn init(a: Allocator, device: vk.PhysicalDevice, surface: vk.SurfaceKHR) !SwapchainSupportInfo {
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

    fn deinit(self: *const SwapchainSupportInfo, a: Allocator) void {
        a.free(self.formats);
        a.free(self.present_modes);
    }

    fn pickSwapchainFormat(self: Self, opts: SwapchainCreateOpts) vk.Format {
        // TODO: Add support for specifying desired format.
        _ = opts;
        for (self.formats) |format| {
            if (format.format == vk.FORMAT_B8G8R8A8_SRGB and
                format.colorSpace == vk.COLOR_SPACE_SRGB_NONLINEAR_KHR)
            {
                return format.format;
            }
        }

        return self.formats[0].format;
    }

    fn pickSwapchainPresentMode(self: Self, opts: SwapchainCreateOpts) vk.PresentModeKHR {
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

    fn makeSwapchainExtent(self: Self, opts: SwapchainCreateOpts) vk.Extent2D {
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

pub const VkError = error{
    NotReady,
    Timeout,
    EventSet,
    EventReset,
    Incomplete,
    ErrorOutOfHostMemory,
    ErrorOutOfDeviceMemory,
    ErrorInitializationFailed,
    ErrorDeviceLost,
    ErrorMemoryMapFailed,
    ErrorLayerNotPresent,
    ErrorExtensionNotPresent,
    ErrorFeatureNotPresent,
    ErrorIncompatibleDriver,
    ErrorTooManyObjects,
    ErrorFormatNotSupported,
    ErrorFragmentedPool,
    ErrorOutOfPoolMemory,
    ErrorInvalidExternalHandle,
    ErrorFragmentation,
    ErrorInvalidOpaqueCaptureAddress,
    PipelineCompileRequired,
    ErrorSurfaceLostKHR,
    ErrorNativeWindowInUseKHR,
    SuboptimalKHR,
    ErrorOutOfDateKHR,
    ErrorIncompatibleDisplayKHR,
    ErrorValidationFailedExt,
    ErrorInvalidShaderNv,
    ErrorImageUsageNotSupportedKHR,
    ErrorVideoPictureLayoutNotSupportedKHR,
    ErrorVideoProfileOperationNotSupportedKHR,
    ErrorVideoProfileFormatNotSupportedKHR,
    ErrorVideoProfileCodecNotSupportedKHR,
    ErrorVideoStdVersionNotSupportedKHR,
    ErrorInvalidDrmFormatModifierPlaneLayoutExt,
    ErrorNotPermittedKHR,
    ErrorFullScreenExclusiveModeLostExt,
    ThreadIdleKHR,
    ThreadDoneKHR,
    OperationDeferredKHR,
    OperationNotDeferredKHR,
    ErrorCompressionExhaustedExt,
    ErrorIncompatibleShaderBinaryExt,
    ErrorUnknown,
};

pub fn checkVk(result: vk.Result) VkError!void {
    return switch (result) {
        vk.SUCCESS => {},
        vk.SUBOPTIMAL_KHR => VkError.SuboptimalKHR,
        vk.NOT_READY => VkError.NotReady,
        vk.TIMEOUT => VkError.Timeout,
        vk.EVENT_SET => VkError.EventSet,
        vk.EVENT_RESET => VkError.EventReset,
        vk.INCOMPLETE => VkError.Incomplete,
        vk.ERROR_OUT_OF_HOST_MEMORY => VkError.ErrorOutOfHostMemory,
        vk.ERROR_OUT_OF_DEVICE_MEMORY => VkError.ErrorOutOfDeviceMemory,
        vk.ERROR_INITIALIZATION_FAILED => VkError.ErrorInitializationFailed,
        vk.ERROR_DEVICE_LOST => VkError.ErrorDeviceLost,
        vk.ERROR_MEMORY_MAP_FAILED => VkError.ErrorMemoryMapFailed,
        vk.ERROR_LAYER_NOT_PRESENT => VkError.ErrorLayerNotPresent,
        vk.ERROR_EXTENSION_NOT_PRESENT => VkError.ErrorExtensionNotPresent,
        vk.ERROR_FEATURE_NOT_PRESENT => VkError.ErrorFeatureNotPresent,
        vk.ERROR_INCOMPATIBLE_DRIVER => VkError.ErrorIncompatibleDriver,
        vk.ERROR_TOO_MANY_OBJECTS => VkError.ErrorTooManyObjects,
        vk.ERROR_FORMAT_NOT_SUPPORTED => VkError.ErrorFormatNotSupported,
        vk.ERROR_FRAGMENTED_POOL => VkError.ErrorFragmentedPool,
        vk.ERROR_UNKNOWN => VkError.ErrorUnknown,
        vk.ERROR_OUT_OF_POOL_MEMORY => VkError.ErrorOutOfPoolMemory,
        vk.ERROR_INVALID_EXTERNAL_HANDLE => VkError.ErrorInvalidExternalHandle,
        vk.ERROR_FRAGMENTATION => VkError.ErrorFragmentation,
        vk.ERROR_INVALID_OPAQUE_CAPTURE_ADDRESS => VkError.ErrorInvalidOpaqueCaptureAddress,
        vk.PIPELINE_COMPILE_REQUIRED => VkError.PipelineCompileRequired,
        vk.ERROR_SURFACE_LOST_KHR => VkError.ErrorSurfaceLostKHR,
        vk.ERROR_NATIVE_WINDOW_IN_USE_KHR => VkError.ErrorNativeWindowInUseKHR,
        vk.ERROR_OUT_OF_DATE_KHR => VkError.ErrorOutOfDateKHR,
        vk.ERROR_INCOMPATIBLE_DISPLAY_KHR => VkError.ErrorIncompatibleDisplayKHR,
        vk.ERROR_VALIDATION_FAILED_EXT => VkError.ErrorValidationFailedExt,
        vk.ERROR_INVALID_SHADER_NV => VkError.ErrorInvalidShaderNv,
        vk.ERROR_IMAGE_USAGE_NOT_SUPPORTED_KHR => VkError.ErrorImageUsageNotSupportedKHR,
        vk.ERROR_VIDEO_PICTURE_LAYOUT_NOT_SUPPORTED_KHR => VkError.ErrorVideoPictureLayoutNotSupportedKHR,
        vk.ERROR_VIDEO_PROFILE_OPERATION_NOT_SUPPORTED_KHR => VkError.ErrorVideoProfileOperationNotSupportedKHR,
        vk.ERROR_VIDEO_PROFILE_FORMAT_NOT_SUPPORTED_KHR => VkError.ErrorVideoProfileFormatNotSupportedKHR,
        vk.ERROR_VIDEO_PROFILE_CODEC_NOT_SUPPORTED_KHR => VkError.ErrorVideoProfileCodecNotSupportedKHR,
        vk.ERROR_VIDEO_STD_VERSION_NOT_SUPPORTED_KHR => VkError.ErrorVideoStdVersionNotSupportedKHR,
        vk.ERROR_INVALID_DRM_FORMAT_MODIFIER_PLANE_LAYOUT_EXT => VkError.ErrorInvalidDrmFormatModifierPlaneLayoutExt,
        vk.ERROR_NOT_PERMITTED_KHR => VkError.ErrorNotPermittedKHR,
        vk.ERROR_FULL_SCREEN_EXCLUSIVE_MODE_LOST_EXT => VkError.ErrorFullScreenExclusiveModeLostExt,
        vk.THREAD_IDLE_KHR => VkError.ThreadIdleKHR,
        vk.THREAD_DONE_KHR => VkError.ThreadDoneKHR,
        vk.OPERATION_DEFERRED_KHR => VkError.OperationDeferredKHR,
        vk.OPERATION_NOT_DEFERRED_KHR => VkError.OperationNotDeferredKHR,
        vk.ERROR_COMPRESSION_EXHAUSTED_EXT => VkError.ErrorCompressionExhaustedExt,
        vk.ERROR_INCOMPATIBLE_SHADER_BINARY_EXT => VkError.ErrorIncompatibleShaderBinaryExt,
        else => VkError.ErrorUnknown,
    };
}
