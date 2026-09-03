const std = @import("std");
const core = @import("../root.zig");
const vma_usage = core.bindings.vma_usage;
const checkVk = core.bindings.vulkan_init.checkVk;
const vk = core.clibs.vk;

pub const CreateInfo = struct {
    alloc_size: usize,
    buffer_usage: core.clibs.vk.BufferUsageFlags,
    mem_usage: core.clibs.vma.MemoryUsage,
    flags: core.clibs.vma.AllocationCreateFlags,
};

creates: std.StringHashMapUnmanaged(CreateInfo) = .empty,

descriptor_set_layout: vk.DescriptorSetLayout = undefined,

pub fn deinit(
    self: *@This(),
    a: std.mem.Allocator,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    self.creates.deinit(a);
    vk.DestroyDescriptorSetLayout(device, self.descriptor_set_layout, alloc_cbs);
}

pub fn upload(
    self: *@This(),
    allocs: core.engine.Allocators,
) std.mem.Allocator.Error!AllocatedData {
    var all_mapped_buffers: std.StringHashMapUnmanaged(core.bindings.vma_usage.MappedBuffer) = .empty;
    var iter = self.creates.iterator();

    while (iter.next()) |mapped| {
        const ci = mapped.value_ptr;
        const alloc = core.bindings.vma_usage.AllocatedBuffer.create(
            allocs.vma,
            ci.alloc_size,
            ci.buffer_usage,
            ci.mem_usage,
            ci.flags,
        );
        var buf = core.bindings.vma_usage.MappedBuffer{
            .allocation = alloc,
        };

        core.bindings.vulkan_init.checkVk(core.clibs.vma.MapMemory(
            allocs.vma,
            alloc.allocation,
            &buf.mapped,
        )) catch @panic("failed to map buffer");
        try all_mapped_buffers.put(allocs.std, mapped.key_ptr.*, buf);
    }

    return .{
        .buffers = all_mapped_buffers,
    };
}

pub fn createDescriptorSetLayoutBinding(
    self: @This(),
    buffer_name: []const u8,
    binding: u32,
    desc_type: vk.DescriptorType,
    stage_flags: u32,
) vk.DescriptorSetLayoutBinding {
    if (!self.creates.contains(buffer_name)) std.debug.panic(
        \\ Tried to create a set layout binding for a buffer that is not present: '{s}'
    , .{buffer_name});

    return vk.DescriptorSetLayoutBinding{
        .binding = binding,
        .descriptorType = desc_type,
        .descriptorCount = 1,
        .stageFlags = stage_flags,
        .pImmutableSamplers = null,
    };

    // const ci = vk.DescriptorSetLayoutCreateInfo{
    //     .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
    //     .bindingCount = @as(u32, @intCast(bindings.len)),
    //     .pBindings = bindings.ptr,
    // };

    // checkVk(vk.CreateDescriptorSetLayout(device, &ci, alloc_cbs, &self.descriptor_set_layout)) catch
    //     @panic("failed to create main compute descriptor set layout");
}

pub const AllocatedData = struct {
    buffers: std.StringHashMapUnmanaged(core.bindings.vma_usage.MappedBuffer) = .empty,

    pub fn deinit(
        self: *@This(),
        allocs: core.engine.Allocators,
    ) void {
        var iter = self.buffers.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocs.vma);
        }
        self.buffers.deinit(allocs.std);
    }

    pub fn createDescriptorSetWrite(
        self: @This(),
        set: vk.DescriptorSet,
        buffer_name: []const u8,
        binding: u32,
        offset: u32,
        desc_type: vk.DescriptorType,
        buf_info_out: *vk.DescriptorBufferInfo,
    ) vk.WriteDescriptorSet {
        if (!self.buffers.contains(buffer_name)) std.debug.panic(
            \\ Tried to create a set write for a buffer that is not present: '{s}'
        , .{buffer_name});

        const buf = self.buffers.get(buffer_name).?;

        buf_info_out.* = vk.DescriptorBufferInfo{
            .buffer = buf.allocation.buffer,
            .offset = offset,
            .range = vk.WHOLE_SIZE,
        };

        return vk.WriteDescriptorSet{
            .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstSet = set,
            .dstBinding = binding,
            .dstArrayElement = 0,
            .descriptorCount = 1,
            .descriptorType = desc_type,
            .pBufferInfo = buf_info_out,
        };
    }
};
