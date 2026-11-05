const std = @import("std");
const core = @import("../root.zig");
const vk = core.clibs.vk;
const checkVk = core.bindings.vulkan_init.checkVk;
const Attachments = core.engine.Renderer.Attachments;
const log = std.log.scoped(.AttachmentResource);

const SetKey = std.EnumSet(Attachments.Tags);

set_layouts: std.AutoHashMapUnmanaged(SetKey, vk.DescriptorSetLayout) = .empty,

pub fn deinit(
    self: *@This(),
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    var iter = self.set_layouts.valueIterator();
    while (iter.next()) |layout|
        vk.DestroyDescriptorSetLayout(device, layout.*, alloc_cbs);
}

pub fn createAndRegisterAttachmentSetLayout(
    self: *@This(),
    a: std.mem.Allocator,
    key: SetKey,
    stage_flags: vk.ShaderStageFlags,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) std.mem.Allocator.Error!void {
    var layout: vk.DescriptorSetLayout = undefined;
    var bindings: [32]vk.DescriptorSetLayoutBinding = undefined;

    var iter = key.iterator();
    var i: usize = 0;
    while (iter.next()) |tag| : (i += 1) {
        bindings[i] = vk.DescriptorSetLayoutBinding{
            .binding = @backingInt(tag),
            .descriptorType = vk.DESCRIPTOR_TYPE_INPUT_ATTACHMENT,
            .descriptorCount = 1,
            .stageFlags = stage_flags,
        };
    }

    var ci = vk.DescriptorSetLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .flags = 0,
        .bindingCount = @intCast(i),
        .pBindings = bindings[0..i].ptr,
    };

    checkVk(vk.CreateDescriptorSetLayout(device, &ci, alloc_cbs, &layout)) catch
        @panic("failed to create descriptor set layout");

    try self.set_layouts.putNoClobber(a, key, layout);
}

pub fn upload(
    self: *@This(),
    a: std.mem.Allocator,
    pool: vk.DescriptorPool,
    device: vk.Device,
) std.mem.Allocator.Error!AllocatedData {
    var sets: std.AutoHashMapUnmanaged(SetKey, vk.DescriptorSet) = .empty;
    var layouts_iter = self.set_layouts.iterator();

    while (layouts_iter.next()) |entry| {
        var set: vk.DescriptorSet = undefined;
        const ai = vk.DescriptorSetAllocateInfo{
            .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = null,
            .descriptorPool = pool,
            .descriptorSetCount = 1,
            .pSetLayouts = entry.value_ptr,
        };

        checkVk(vk.AllocateDescriptorSets(device, &ai, &set)) catch |e| {
            log.err(
                \\failed to allocate texture descriptor set: {s}
            , .{@errorName(e)});
            @panic("failed to allocate texture descriptor set");
        };

        try sets.put(a, entry.key_ptr.*, set);
    }

    return .{
        .sets = sets,
    };
}

pub const AllocatedData = struct {
    sets: std.AutoHashMapUnmanaged(SetKey, vk.DescriptorSet),

    pub fn updateSet(
        self: @This(),
        key: SetKey,
        swapchain: *const core.engine.Renderer.Swapchain,
        device: vk.Device,
    ) void {
        const set = self.sets.get(key).?;

        var writes: [32]vk.WriteDescriptorSet = undefined;
        var infos: [32]vk.DescriptorImageInfo = undefined;

        var iter = key.iterator();
        var i: usize = 0;
        while (iter.next()) |tag| : (i += 1) {
            const image = swapchain.attachments.plexe.get(tag).image;

            infos[i] = .{
                .imageLayout = if (core.engine.Renderer.Attachments.isDepthAttachment(tag))
                    vk.IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL
                else
                    vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                .sampler = null,
                .imageView = image.view,
            };

            writes[i] = .{
                .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
                .dstSet = set,
                .dstBinding = @backingInt(tag),
                .dstArrayElement = 0,
                .descriptorCount = 1,
                .descriptorType = vk.DESCRIPTOR_TYPE_INPUT_ATTACHMENT,
                .pImageInfo = &infos[i],
            };
        }

        vk.UpdateDescriptorSets(device, @intCast(i), writes[0..i].ptr, 0, null);
    }
};
