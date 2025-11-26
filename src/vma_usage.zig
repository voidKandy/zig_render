const std = @import("std");
const root = @import("root.zig");
const checkVk = root.vulkan_init.checkVk;
const c = @import("clibs.zig");
const vk = c.vk;

pub const AllocatedBuffer = struct {
    buffer: vk.Buffer,
    allocation: c.vma.Allocation,

    pub fn create(
        vma_a: c.vma.Allocator,
        alloc_size: usize,
        usage: c.vk.BufferUsageFlags,
        memory_usage: c.vma.MemoryUsage,
        flags: c.vma.AllocationCreateFlags,
    ) AllocatedBuffer {
        const buffer_ci = c.vk.BufferCreateInfo{
            .sType = c.vk.STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .size = alloc_size,
            .usage = usage,
        };

        const vma_alloc_info = c.vma.AllocationCreateInfo{
            .usage = memory_usage,
            .requiredFlags = flags,
        };

        var buffer: AllocatedBuffer = undefined;
        checkVk(c.vma.CreateBuffer(vma_a, &buffer_ci, &vma_alloc_info, &buffer.buffer, &buffer.allocation, null)) catch @panic("Failed to create buffer");

        return buffer;
    }
};

pub const AllocatedImage = struct {
    allocation: c.vma.Allocation,
    image: vk.Image,
    view: vk.ImageView,
    extent: vk.Extent3D,
    format: vk.Format,
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
