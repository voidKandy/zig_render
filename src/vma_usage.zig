const std = @import("std");
const root = @import("root.zig");
const vki = root.vulkan_init;
const checkVk = vki.checkVk;
const c = @import("clibs.zig");
const vk = c.vk;

pub const MappedBuffer = struct {
    allocation: AllocatedBuffer,
    mapped: ?*anyopaque = undefined,

    pub fn deinit(self: @This(), vma_a: c.vma.Allocator) void {
        c.vma.UnmapMemory(vma_a, self.allocation.allocation);
        self.allocation.deinit(vma_a);
    }
};

pub const AllocatedBuffer = struct {
    buffer: vk.Buffer = undefined,
    allocation: c.vma.Allocation = undefined,
    size: usize,

    pub fn create(
        vma_a: c.vma.Allocator,
        alloc_size: usize,
        usage: c.vk.BufferUsageFlags,
        memory_usage: c.vma.MemoryUsage,
        flags: c.vma.AllocationCreateFlags,
    ) @This() {
        const buffer_ci = c.vk.BufferCreateInfo{
            .sType = c.vk.STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = alloc_size,
            .usage = usage,
        };

        const vma_alloc_info = c.vma.AllocationCreateInfo{
            .usage = memory_usage,
            .requiredFlags = flags,
        };

        var buffer = AllocatedBuffer{
            .size = alloc_size,
        };

        checkVk(c.vma.CreateBuffer(vma_a, &buffer_ci, &vma_alloc_info, &buffer.buffer, &buffer.allocation, null)) catch @panic("Failed to create buffer");

        return buffer;
    }

    pub fn deinit(self: @This(), vma_a: c.vma.Allocator) void {
        c.vma.DestroyBuffer(vma_a, self.buffer, self.allocation);
    }
};

pub const AllocatedImage = struct {
    allocation: c.vma.Allocation = undefined,
    image: vk.Image = undefined,
    view: vk.ImageView = undefined,
    extent: vk.Extent3D,
    format: vk.Format,

    /// Image view must still be created after AllocatedImage is initialized
    /// Do this by initializing some create info
    /// and then vk.CreateImageView
    pub fn init(
        vma_a: c.vma.Allocator,
        format: vk.Format,
        extent: vk.Extent3D,
        usages: vk.ImageUsageFlags,
    ) @This() {
        var image: @This() = .{
            .format = format,
            .extent = extent,
        };

        const ci = vki.imageCreateInfo(image.format, usages, image.extent);

        const ai = c.vma.AllocationCreateInfo{
            .usage = c.vma.MEMORY_USAGE_GPU_ONLY,
            .requiredFlags = vk.MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        };

        checkVk(c.vma.CreateImage(vma_a, &ci, &ai, &image.image, &image.allocation, null)) catch
            @panic("failed to create draw image");

        return image;
    }

    pub fn deinit(self: @This(), vma_a: c.vma.Allocator, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
        vk.DestroyImageView(device, self.view, alloc_cbs);
        c.vma.DestroyImage(vma_a, self.image, self.allocation);
    }
};

pub fn findMemoryType(physical_device: vk.PhysicalDevice, type_filter: u32, properties: vk.MemoryPropertyFlags) u32 {
    var mem_properties: vk.PhysicalDeviceMemoryProperties = undefined;
    vk.GetPhysicalDeviceMemoryProperties(physical_device, &mem_properties);

    for (0..mem_properties.memoryTypeCount) |i| {
        if (((type_filter & (@as(u32, 1) << @as(u5, @intCast(i)))) != 0) and (mem_properties.memoryTypes[i].propertyFlags & properties) == properties) {
            return @as(u32, @intCast(i));
        }
    }

    @panic("failed to find suitable memory type!");
}

pub const VulkanDeleter = struct {
    object: ?*anyopaque,
    callbacks: ?*vk.AllocationCallbacks,
    deleteFn: *const fn (entry: *VulkanDeleter, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void,

    pub fn delete(self: *VulkanDeleter, device: vk.Device) void {
        self.deleteFn(self, device, self.callbacks);
    }

    pub fn flushList(list: std.ArrayList(@This()), device: vk.Device) void {
        for (list.items) |*entry| {
            entry.delete(device);
        }
    }

    pub fn make(
        object: anytype,
        func: anytype,
        cbs: ?*vk.AllocationCallbacks,
    ) VulkanDeleter {
        const T = @TypeOf(object);
        comptime {
            std.debug.assert(@typeInfo(T) == .optional);
            const Ptr = @typeInfo(T).optional.child;
            std.debug.assert(@typeInfo(Ptr) == .pointer);
            std.debug.assert(@typeInfo(Ptr).pointer.size == .one);

            const Fn = @TypeOf(func);
            std.debug.assert(@typeInfo(Fn) == .@"fn");
        }

        return VulkanDeleter{
            .object = object,
            .callbacks = cbs,
            .deleteFn = struct {
                fn del(
                    entry: *VulkanDeleter,
                    device: vk.Device,
                    alloc_cbs: ?*vk.AllocationCallbacks,
                ) void {
                    const obj: @TypeOf(object) = @ptrCast(entry.object);
                    func(device, obj, alloc_cbs);
                }
            }.del,
        };
    }
};

pub const VmaBufferDeleter = struct {
    buffer: AllocatedBuffer,

    pub fn delete(self: *VmaBufferDeleter, allocator: c.vma.Allocator) void {
        c.vma.DestroyBuffer(allocator, self.buffer.buffer, self.buffer.allocation);
    }

    pub fn flushList(list: std.ArrayList(@This()), vma_a: c.vma.Allocator) void {
        for (list.items) |*entry| {
            entry.delete(vma_a);
        }
    }
};

pub const VmaImageDeleter = struct {
    image: AllocatedImage,
    callbacks: ?*vk.AllocationCallbacks,

    pub fn delete(
        self: *VmaImageDeleter,
        allocator: c.vma.Allocator,
        device: vk.Device,
    ) void {
        c.vma.DestroyImage(allocator, self.image.image, self.image.allocation);
        vk.DestroyImageView(device, self.image.view, self.callbacks);
    }

    pub fn flushList(list: std.ArrayList(@This()), vma_a: c.vma.Allocator, device: vk.Device) void {
        for (list.items) |*entry| {
            entry.delete(vma_a, device);
        }
    }
};
