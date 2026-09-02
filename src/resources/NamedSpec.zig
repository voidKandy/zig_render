const std = @import("std");
const core = @import("../root.zig");
const vk = core.clibs.vk;
const checkVk = core.bindings.vulkan_init.checkVk;

pub const BindingSource = union(enum) {
    /// storage image, e.g. compute write target
    storage_texture: []const u8,
    /// combined sampler, e.g. fragment shader read
    sampled_texture: []const u8,
    /// storage buffer, from Manager.mapped_buffers
    buffer: []const u8,
};

pub const BindingSpec = struct {
    binding: u32,
    stage_flags: vk.ShaderStageFlags,
    source: BindingSource,

    fn descriptorType(self: BindingSpec) vk.DescriptorType {
        return switch (self.source) {
            .storage_texture => vk.DESCRIPTOR_TYPE_STORAGE_IMAGE,
            .sampled_texture => vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
            .buffer => vk.DESCRIPTOR_TYPE_STORAGE_BUFFER,
        };
    }
};

pub const NamedSetSpec = struct {
    name: []const u8,
    bindings: []const BindingSpec,
};

spec: NamedSetSpec,

descriptor_set_layout: vk.DescriptorSetLayout = undefined,

pub fn createDescriptorSetLayout(
    self: *@This(),
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    var vk_bindings: [16]vk.DescriptorSetLayoutBinding = undefined;
    for (self.spec.bindings, 0..) |b, i| {
        vk_bindings[i] = .{
            .binding = b.binding,
            .descriptorType = b.descriptorType(),
            .descriptorCount = 1,
            .stageFlags = b.stage_flags,
        };
    }
    const ci = vk.DescriptorSetLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = @intCast(self.spec.bindings.len),
        .pBindings = &vk_bindings,
    };
    checkVk(vk.CreateDescriptorSetLayout(device, &ci, alloc_cbs, &self.descriptor_set_layout)) catch
        @panic("failed to create descriptor set layout from spec");
}
