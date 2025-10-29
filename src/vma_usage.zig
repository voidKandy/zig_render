const std = @import("std");
const c = @import("clibs.zig");
const vk = c.vk;

pub const AllocatedBuffer = struct {
    buffer: vk.Buffer,
    allocation: c.vma.Allocation,
};

pub const AllocatedImage = struct {
    image: vk.Image,
    allocation: c.vma.Allocation,
};

pub fn findMemoryType(physical_device: vk.PhysicalDevice, type_filter: u32, properties: vk.MemoryPropertyFlags) u32 {
    const mem_properties: vk.PhysicalDeviceMemoryProperties = undefined;
    vk.GetPhysicalDeviceMemoryProperties(physical_device, &mem_properties);

    for (0..mem_properties.memoryTypeCount) |i| {
        if ((type_filter & (1 << i)) and (mem_properties.memoryTypes[i].propertyFlags & properties) == properties) {
            return i;
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
};

pub const VmaImageDeleter = struct {
    image: AllocatedImage,

    pub fn delete(self: *VmaImageDeleter, allocator: c.vma.Allocator) void {
        c.vma.DestroyImage(allocator, self.image.image, self.image.allocation);
    }
};
