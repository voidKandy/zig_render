const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("../root.zig");
const c = core.clibs;
const vma_usage = core.bindings.vma_usage;
const vk = c.vk;
const log = std.log.scoped(.vulkan_init);
const Mat4 = core.lib.math.Mat4;

pub fn imageSubresourceRange(aspect_mask: vk.ImageAspectFlags) vk.ImageSubresourceRange {
    return .{
        .aspectMask = aspect_mask,
        .baseMipLevel = 0,
        .levelCount = vk.REMAINING_MIP_LEVELS,
        .baseArrayLayer = 0,
        .layerCount = vk.REMAINING_ARRAY_LAYERS,
    };
}

pub fn imageCreateInfo(format: vk.Format, usage_flags: vk.ImageUsageFlags, extent: vk.Extent3D) vk.ImageCreateInfo {
    return .{
        .sType = vk.STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = null,
        .imageType = vk.IMAGE_TYPE_2D,
        .format = format,
        .extent = extent,
        .mipLevels = 1,
        .arrayLayers = 1,
        //for MSAA. we will not be using it by default, so default it to 1 sample per pixel.
        .samples = vk.SAMPLE_COUNT_1_BIT,
        //optimal tiling, which means the image is stored on the best gpu format
        .tiling = vk.IMAGE_TILING_OPTIMAL,
        .usage = usage_flags,
    };
}

pub fn imageViewCreateInfo(format: vk.Format, image: vk.Image, aspect_flags: vk.ImageAspectFlags) vk.ImageViewCreateInfo {
    return .{
        .sType = vk.STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .pNext = null,

        .viewType = vk.IMAGE_VIEW_TYPE_2D,
        .image = image,
        .format = format,
        .subresourceRange = .{
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
            .aspectMask = aspect_flags,
        },
    };
}

pub fn pipelineShaderStageCreateInfo(stage: vk.ShaderStageFlagBits, shader_module: vk.ShaderModule, entry: [:0]const u8) vk.PipelineShaderStageCreateInfo {
    return .{
        .sType = vk.STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO,
        .pNext = null,
        .stage = stage,
        .module = shader_module,
        .pName = entry,
    };
}

pub const UploadContext = struct {
    upload_fence: c.vk.Fence = null,
    command_pool: c.vk.CommandPool = null,
    command_buffer: c.vk.CommandBuffer = null,

    const Self = @This();

    pub fn initCommands(self: *Self, device: vk.Device, phys_device: PhysicalDevice, vk_alloc_cbs: ?*vk.AllocationCallbacks) void {
        const upload_command_pool_ci = vk.CommandPoolCreateInfo{
            .sType = vk.STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .flags = 0,
            .queueFamilyIndex = phys_device.graphics_queue_family,
        };

        checkVk(vk.CreateCommandPool(device, &upload_command_pool_ci, vk_alloc_cbs, &self.command_pool)) catch @panic("Failed to create upload command pool");

        const upload_command_buffer_ai = vk.CommandBufferAllocateInfo{
            .sType = vk.STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .commandPool = self.command_pool,
            .level = vk.COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1,
        };

        checkVk(vk.AllocateCommandBuffers(device, &upload_command_buffer_ai, &self.command_buffer)) catch @panic("Failed to allocate upload command buffer");
    }

    pub fn initSyncObjects(self: *Self, device: vk.Device, vk_alloc_cbs: ?*vk.AllocationCallbacks) void {
        const upload_fence_ci = vk.FenceCreateInfo{
            .sType = vk.STRUCTURE_TYPE_FENCE_CREATE_INFO,
        };

        checkVk(vk.CreateFence(device, &upload_fence_ci, vk_alloc_cbs, &self.upload_fence)) catch @panic("Failed to create upload fence");
    }

    pub fn deinit(self: *Self, device: vk.Device, vk_alloc_cbs: ?*vk.AllocationCallbacks) void {
        vk.DestroyCommandPool(device, self.command_pool, vk_alloc_cbs);
        vk.DestroyFence(device, self.upload_fence, vk_alloc_cbs);
    }

    /// `submit_ctx` must be a struct with a `submit` function.
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

            if (submit_fn_info.@"fn".param_attrs.len != 2) {
                @compileError("Context submit method should have two parameters");
            }

            if (submit_fn_info.@"fn".param_types[0] != Context) {
                @compileError("Context submit method first parameter should be of type: " ++ @typeName(Context) ++ " instead got: " ++ @typeName(submit_fn_info.@"fn".params[0].type.?));
            }

            if (submit_fn_info.@"fn".param_types[1] != c.vk.CommandBuffer) {
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

        var debug = opts.debug;

        var arena_state = std.heap.ArenaAllocator.init(alloc);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        // Get supported layers and extensions
        var layer_count: u32 = undefined;
        try checkVk(vk.EnumerateInstanceLayerProperties(&layer_count, null));

        var extension_count: u32 = undefined;
        try checkVk(vk.EnumerateInstanceExtensionProperties(null, &extension_count, null));
        const extension_props = try arena.alloc(vk.ExtensionProperties, extension_count);
        try checkVk(vk.EnumerateInstanceExtensionProperties(null, &extension_count, extension_props.ptr));

        var layers = std.ArrayListUnmanaged([*c]const u8).empty;
        if (debug) {
            const validation_layer_name: [*c]const u8 = "VK_LAYER_KHRONOS_validation";
            try layers.append(arena, validation_layer_name);
        }

        // Check if the required extensions are supported
        var extensions = std.ArrayListUnmanaged([*c]const u8).empty;

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
        if (debug and ExtensionFinder.find("VK_EXT_debug_utils", extension_props)) {
            try extensions.append(arena, "VK_EXT_debug_utils");
        } else {
            debug = false;
        }

        const app_info = vk.ApplicationInfo{
            .sType = vk.STRUCTURE_TYPE_APPLICATION_INFO,
            .apiVersion = opts.api_version,
            .pApplicationName = opts.application_name,
            .pEngineName = opts.engine_name orelse opts.application_name,
        };

        log.info(
            \\ Creating Instance with extensions:
        , .{});
        for (extensions.items) |i| {
            log.info(
                \\ {s}
            , .{i});
        }
        const validation_features = vk.ValidationFeaturesEXT{
            .sType = vk.STRUCTURE_TYPE_VALIDATION_FEATURES_EXT,
            .enabledValidationFeatureCount = 1,
            .pEnabledValidationFeatures = &[_]vk.ValidationFeatureEnableEXT{
                vk.VALIDATION_FEATURE_ENABLE_DEBUG_PRINTF_EXT,
            },
        };

        const instance_info = vk.InstanceCreateInfo{
            .pNext = if (debug) &validation_features else null,
            .flags = vk.INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR,
            .sType = vk.STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pApplicationInfo = &app_info,
            .enabledLayerCount = @as(u32, @intCast(layers.items.len)),
            .ppEnabledLayerNames = layers.items.ptr,
            .enabledExtensionCount = @as(u32, @intCast(extensions.items.len)),
            .ppEnabledExtensionNames = extensions.items.ptr,
        };

        var instance: vk.Instance = undefined;
        try checkVk(vk.CreateInstance(&instance_info, opts.alloc_cb, &instance));
        log.info("Created vulkan instance.", .{});

        const debug_messenger = if (debug)
            try createDebugMessenger(instance, opts)
        else
            null;

        return .{
            .handle = instance,
            .debug_messenger = debug_messenger,
        };
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

    fn createDebugMessenger(instance: vk.Instance, opts: Options) !vk.DebugUtilsMessengerEXT {
        const createFn = getVulkanInstanceFunct(
            vk.PFN_CreateDebugUtilsMessengerEXT,
            instance,
            "vkCreateDebugUtilsMessengerEXT",
        ) orelse @panic("could not get create debug utils messenger ext function");
        const ci = vk.DebugUtilsMessengerCreateInfoEXT{
            .sType = vk.STRUCTURE_TYPE_DEBUG_UTILS_MESSENGER_CREATE_INFO_EXT,
            .messageSeverity = vk.DEBUG_UTILS_MESSAGE_SEVERITY_VERBOSE_BIT_EXT |
                vk.DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT |
                vk.DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT,
            .messageType = vk.DEBUG_UTILS_MESSAGE_TYPE_GENERAL_BIT_EXT |
                vk.DEBUG_UTILS_MESSAGE_TYPE_VALIDATION_BIT_EXT |
                vk.DEBUG_UTILS_MESSAGE_TYPE_PERFORMANCE_BIT_EXT,
            .pfnUserCallback = opts.debug_callback orelse defaultDebugCallback,
            .pUserData = null,
        };
        var debug_messenger: vk.DebugUtilsMessengerEXT = undefined;
        try checkVk(createFn(instance, &ci, opts.alloc_cb, &debug_messenger));
        log.info("Created vulkan debug messenger.", .{});
        return debug_messenger;
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

        // BAD that this is here?
        const swapchain_support = try core.engine.Renderer.Swapchain.SupportInfo.init(arena, self.handle, opts.surface);
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
                log.warn("Checking for ext: {s}\n", .{req_ext});
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
/// Result from the creation of a logical device.
///
pub const LogicalDevice = struct {
    handle: vk.Device = null,
    graphics_queue: vk.Queue = null,
    present_queue: vk.Queue = null,
    compute_queue: vk.Queue = null,
    transfer_queue: vk.Queue = null,

    const CreateOpts = struct {
        /// The physical device.
        physical_device: PhysicalDevice,
        /// The logical device features.
        features: vk.PhysicalDeviceFeatures = undefined,
        /// The logical device allocation callbacks.
        alloc_cb: ?*const vk.AllocationCallbacks = null,
        /// Optional pnext chain for VkDeviceCreateInfo.
        pnext: ?*const anyopaque = null,
        device_extensions: []const [*c]const u8 = &.{},
    };
    /// Helper function for initializing descriptor indexing struct
    /// must be `pNext` of createOpts
    pub fn descriptorIndexingFeatures() vk.PhysicalDeviceDescriptorIndexingFeatures {
        return vk.PhysicalDeviceDescriptorIndexingFeatures{
            .sType = vk.STRUCTURE_TYPE_PHYSICAL_DEVICE_DESCRIPTOR_INDEXING_FEATURES,
            .shaderSampledImageArrayNonUniformIndexing = vk.TRUE,
            .runtimeDescriptorArray = vk.TRUE,
            .descriptorBindingVariableDescriptorCount = vk.TRUE,
            .descriptorBindingPartiallyBound = vk.TRUE,
        };
    }

    /// Create logical device
    ///
    /// # Allocations
    /// This function does not require persistent allocations.
    pub fn create(a: Allocator, opts: CreateOpts) !LogicalDevice {
        var arena_state = std.heap.ArenaAllocator.init(a);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var queue_create_infos = std.ArrayListUnmanaged(vk.DeviceQueueCreateInfo).empty;
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

        const device_info = vk.DeviceCreateInfo{
            .sType = vk.STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = opts.pnext,
            .queueCreateInfoCount = @as(u32, @intCast(queue_create_infos.items.len)),
            .pQueueCreateInfos = queue_create_infos.items.ptr,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = @as(u32, @intCast(opts.device_extensions.len)),
            .ppEnabledExtensionNames = opts.device_extensions.ptr,
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
