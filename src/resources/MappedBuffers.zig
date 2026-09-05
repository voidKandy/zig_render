const std = @import("std");
const core = @import("../root.zig");
const log = std.log.scoped(.MappedBuffers);
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

buffer_set_layouts: std.StringHashMapUnmanaged(BufferSetLayout) = undefined,

const BufferSetLayout = struct {
    layout: vk.DescriptorSetLayout,
    infos: []const CreateBufferInfo,
};

pub fn deinit(
    self: *@This(),
    a: std.mem.Allocator,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    self.creates.deinit(a);

    var layouts_iter = self.buffer_set_layouts.valueIterator();
    while (layouts_iter.next()) |layout| {
        vk.DestroyDescriptorSetLayout(device, layout.layout, alloc_cbs);
        // a.free(layout.infos);
    }
    self.buffer_set_layouts.deinit(a);
}

pub const CreateBufferInfo = struct {
    name: []const u8,
    binding: u32,
    descriptor_type: vk.DescriptorType,
    stage_flags: vk.ShaderStageFlags,
};

pub fn createAndRegisterBufferSetLayout(
    self: *@This(),
    a: std.mem.Allocator,
    set_name: []const u8,
    buffer_infos: []const CreateBufferInfo,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) std.mem.Allocator.Error!void {
    var layout: vk.DescriptorSetLayout = undefined;
    // var all_names = try a.alloc([]const u8, buffer_infos.len);
    std.debug.assert(buffer_infos.len <= 32);
    var bindings: [32]vk.DescriptorSetLayoutBinding = undefined;
    for (buffer_infos, 0..) |info, i| {
        if (!self.creates.contains(info.name)) std.debug.panic(
            \\ tried to register buffer '{s}' but it does not exist in creates map!
        , .{info.name});

        bindings[i] = vk.DescriptorSetLayoutBinding{
            .binding = info.binding,
            .descriptorType = info.descriptor_type,
            .descriptorCount = 1,
            .stageFlags = info.stage_flags,
            .pImmutableSamplers = null,
        };
        // all_names[i] = info.name;
    }

    const ci = vk.DescriptorSetLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = @as(u32, @intCast(buffer_infos.len)),
        .pBindings = bindings[0..buffer_infos.len].ptr,
    };

    checkVk(vk.CreateDescriptorSetLayout(device, &ci, alloc_cbs, &layout)) catch
        @panic("failed to create descriptor set layout for buffers");

    const get_or_put = try self.buffer_set_layouts.getOrPut(a, set_name);
    if (get_or_put.found_existing) std.debug.panic(
        \\ SET for '{s}' already exists!
    , .{set_name});

    get_or_put.value_ptr.* = .{
        .layout = layout,
        .infos = buffer_infos,
    };
}

pub fn upload(
    self: *@This(),
    allocs: core.engine.Allocators,
    pool: vk.DescriptorPool,
    device: vk.Device,
) std.mem.Allocator.Error!AllocatedData {
    var all_mapped_buffers: std.StringHashMapUnmanaged(core.bindings.vma_usage.MappedBuffer) = .empty;
    var all_mapped_iter = self.creates.iterator();

    while (all_mapped_iter.next()) |mapped| {
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

    var buffer_sets: std.StringHashMapUnmanaged(AllocatedData.BufferSet) = .empty;
    var buffer_layouts_iter = self.buffer_set_layouts.iterator();
    while (buffer_layouts_iter.next()) |entry| {
        var set: vk.DescriptorSet = undefined;
        const ai = vk.DescriptorSetAllocateInfo{
            .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = pool,
            .descriptorSetCount = 1,
            .pSetLayouts = &entry.value_ptr.layout,
        };

        checkVk(vk.AllocateDescriptorSets(device, &ai, &set)) catch |e| {
            log.err(
                \\failed to allocate texture descriptor set: {s}
            , .{@errorName(e)});
            @panic("failed to allocate texture descriptor set");
        };

        try buffer_sets.put(allocs.std, entry.key_ptr.*, .{
            .set = set,
            .infos = entry.value_ptr.infos,
        });
    }

    return .{
        .buffers = all_mapped_buffers,
        .buffer_sets = buffer_sets,
    };
}

// pub fn createDescriptorSetLayoutBinding(
//     self: @This(),
//     buffer_name: []const u8,
//     binding: u32,
//     desc_type: vk.DescriptorType,
//     stage_flags: u32,
// ) vk.DescriptorSetLayoutBinding {
//     if (!self.creates.contains(buffer_name)) std.debug.panic(
//         \\ Tried to create a set layout binding for a buffer that is not present: '{s}'
//     , .{buffer_name});

//     return vk.DescriptorSetLayoutBinding{
//         .binding = binding,
//         .descriptorType = desc_type,
//         .descriptorCount = 1,
//         .stageFlags = stage_flags,
//         .pImmutableSamplers = null,
//     };

// const ci = vk.DescriptorSetLayoutCreateInfo{
//     .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
//     .bindingCount = @as(u32, @intCast(bindings.len)),
//     .pBindings = bindings.ptr,
// };

// checkVk(vk.CreateDescriptorSetLayout(device, &ci, alloc_cbs, &self.descriptor_set_layout)) catch
//     @panic("failed to create main compute descriptor set layout");
// }

pub const AllocatedData = struct {
    buffers: std.StringHashMapUnmanaged(core.bindings.vma_usage.MappedBuffer) = .empty,
    buffer_sets: std.StringHashMapUnmanaged(BufferSet) = .empty,

    const BufferSet = struct {
        set: vk.DescriptorSet,
        infos: []const CreateBufferInfo,
    };

    pub fn deinit(
        self: *@This(),
        allocs: core.engine.Allocators,
    ) void {
        var iter = self.buffers.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocs.vma);
        }
        self.buffers.deinit(allocs.std);

        // var set_iter = self.buffer_sets.valueIterator();
        // while (set_iter.next()) |set| {
        //     allocs.std.free(set.names);
        // }
        self.buffer_sets.deinit(allocs.std);
    }

    // pub fn createDescriptorSetWrite(
    //     self: @This(),
    //     set: vk.DescriptorSet,
    //     buffer_name: []const u8,
    //     binding: u32,
    //     offset: u32,
    //     desc_type: vk.DescriptorType,
    //     buf_info_out: *vk.DescriptorBufferInfo,
    // ) vk.WriteDescriptorSet {
    //     if (!self.buffers.contains(buffer_name)) std.debug.panic(
    //         \\ Tried to create a set write for a buffer that is not present: '{s}'
    //     , .{buffer_name});

    //     const buf = self.buffers.get(buffer_name).?;

    //     buf_info_out.* = vk.DescriptorBufferInfo{
    //         .buffer = buf.allocation.buffer,
    //         .offset = offset,
    //         .range = vk.WHOLE_SIZE,
    //     };

    //     return vk.WriteDescriptorSet{
    //         .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
    //         .dstSet = set,
    //         .dstBinding = binding,
    //         .dstArrayElement = 0,
    //         .descriptorCount = 1,
    //         .descriptorType = desc_type,
    //         .pBufferInfo = buf_info_out,
    //     };
    // }

    pub fn updateBufferSet(
        self: @This(),
        device: vk.Device,
        set_name: []const u8,
    ) void {
        const set = self.buffer_sets.get(set_name) orelse std.debug.panic(
            \\ tried to update buffer set '{s}' but it does not exist!
        , .{set_name});

        std.debug.assert(set.infos.len <= 32);
        var writes: [32]vk.WriteDescriptorSet = undefined;

        for (set.infos, 0..) |info, i| {
            const buf = self.buffers.get(info.name) orelse std.debug.panic(
                \\ tried to access buffer '{s}' but it does not exist!
            , .{info.name});

            const buffer_info = vk.DescriptorBufferInfo{
                .buffer = buf.allocation.buffer,
                .offset = i,
                .range = vk.WHOLE_SIZE,
            };

            writes[i] = vk.WriteDescriptorSet{
                .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = set.set,
                .dstBinding = info.binding,
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = info.descriptor_type,
                .pBufferInfo = &buffer_info,
            };
        }

        vk.UpdateDescriptorSets(device, @intCast(set.infos.len), writes[0..set.infos.len].ptr, 0, null);
    }
};
