const std = @import("std");
const c = @import("clibs.zig");
const vki = @import("vulkan_init.zig");
const vk = c.vk;
const vma = c.vma;
const checkVk = vki.checkVk;

pub const PoolSizeRatio = struct {
    typ: vk.DescriptorType,
    ratio: f32,
};

pub const Allocator = struct {
    vk_alloc_cbs: ?*vk.AllocationCallbacks,
    allocator: std.mem.Allocator,
    pool: vk.DescriptorPool = undefined,

    const Self = @This();

    pub fn init(a: std.mem.Allocator, vk_alloc_cbs: ?*vk.AllocationCallbacks) Self {
        return .{ .allocator = a, .vk_alloc_cbs = vk_alloc_cbs };
    }

    pub fn deinit(self: *Self, device: vk.Device) void {
        vk.DestroyDescriptorPool(device, self.pool, self.vk_alloc_cbs);
    }

    pub fn initPool(self: *Self, device: vk.Device, max_sets: u32, ratios: []const PoolSizeRatio) void {
        const sizes = self.allocator.alloc(vk.DescriptorPoolSize, ratios.len) catch @panic("out of memory");
        defer self.allocator.free(sizes);

        for (sizes, 0..) |*s, i| {
            s.* = vk.DescriptorPoolSize{ .type = ratios[i].typ, .descriptorCount = @as(u32, @intFromFloat(ratios[i].ratio * @as(f32, @floatFromInt(max_sets)))) };
        }

        const ci = vk.DescriptorPoolCreateInfo{
            .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .flags = 0,
            .maxSets = max_sets,
            .poolSizeCount = @intCast(sizes.len),
            .pPoolSizes = sizes.ptr,
        };

        checkVk(vk.CreateDescriptorPool(device, &ci, self.vk_alloc_cbs, &self.pool)) catch @panic("failed to create descriptor pool");
    }

    pub fn clearDescriptors(self: *Self, device: vk.Device) void {
        checkVk(vk.ResetDescriptorPool(device, self.pool, 0)) catch @panic("failed to reset descriptor pool");
    }

    pub fn allocate(self: *Self, device: vk.Device, layout: vk.DescriptorSetLayout) vk.DescriptorSet {
        const ai =
            vk.DescriptorSetAllocateInfo{
                .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
                .pNext = null,
                .descriptorPool = self.pool,
                .descriptorSetCount = 1,
                .pSetLayouts = &layout,
            };

        var ds: vk.DescriptorSet = undefined;
        checkVk(vk.AllocateDescriptorSets(device, &ai, &ds)) catch @panic("failed to allocate descriptor sets");

        return ds;
    }
};

pub const default_initial_sets: u32 = 64;
/// BAD
pub const default_pool_ratios = &[_]PoolSizeRatio{
    // MUST have at least one for depth image
    .{ .typ = vk.DESCRIPTOR_TYPE_STORAGE_IMAGE, .ratio = 1.0 },

    .{ .typ = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER, .ratio = 1.0 },
    .{ .typ = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC, .ratio = 0.5 },

    .{ .typ = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER, .ratio = 1.0 },
    .{ .typ = vk.DESCRIPTOR_TYPE_STORAGE_BUFFER_DYNAMIC, .ratio = 0.5 },

    .{ .typ = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .ratio = 4.0 },

    .{ .typ = vk.DESCRIPTOR_TYPE_SAMPLED_IMAGE, .ratio = 1.0 },
    .{ .typ = vk.DESCRIPTOR_TYPE_SAMPLER, .ratio = 1.0 },
};

pub const DynamicAllocator = struct {
    const Self = @This();

    vk_alloc_cbs: ?*vk.AllocationCallbacks,
    allocator: std.mem.Allocator,
    ratios: []PoolSizeRatio,
    full_pools: std.ArrayList(vk.DescriptorPool),
    ready_pools: std.ArrayList(vk.DescriptorPool),
    sets_per_pool: u32,

    pub fn init(a: std.mem.Allocator, vk_alloc_cbs: ?*vk.AllocationCallbacks, device: vk.Device, initial_sets: u32, ratios: []const PoolSizeRatio) std.mem.Allocator.Error!Self {
        const alloc_ratios = try a.alloc(PoolSizeRatio, ratios.len);
        @memcpy(alloc_ratios, ratios);
        var self = Self{
            .ratios = alloc_ratios,
            .allocator = a,
            .full_pools = try std.ArrayList(vk.DescriptorPool).initCapacity(a, 16),
            .ready_pools = try std.ArrayList(vk.DescriptorPool).initCapacity(a, 16),
            .sets_per_pool = @intFromFloat(@as(f32, @floatFromInt(initial_sets)) * 1.5),
            .vk_alloc_cbs = vk_alloc_cbs,
        };

        const new_pool = self.createPool(device);
        try self.ready_pools.append(self.allocator, new_pool);
        return self;
    }

    pub fn deinit(self: *Self, device: vk.Device) void {
        self.allocator.free(self.ratios);
        self.destroyPools(device);
        self.full_pools.deinit(self.allocator);
        self.ready_pools.deinit(self.allocator);
    }

    pub fn clearPools(self: *Self, device: vk.Device) void {
        for (self.ready_pools.items) |pool| {
            checkVk(vk.ResetDescriptorPool(device, pool, 0)) catch @panic("failed to reset ready descriptor pools");
        }
        for (self.full_pools.items) |pool| {
            checkVk(vk.ResetDescriptorPool(device, pool, 0)) catch @panic("failed to reset full descriptor pools");
            self.ready_pools.append(self.allocator, pool);
        }

        self.full_pools.clearRetainingCapacity();
    }

    pub fn destroyPools(self: *Self, device: vk.Device) void {
        for (self.ready_pools.items) |pool|
            vk.DestroyDescriptorPool(device, pool, self.vk_alloc_cbs);

        for (self.full_pools.items) |pool|
            vk.DestroyDescriptorPool(device, pool, self.vk_alloc_cbs);

        self.full_pools.clearRetainingCapacity();
    }

    pub fn allocate(self: *Self, device: vk.Device, layout: vk.DescriptorSetLayout, p_next: ?*const anyopaque) vk.DescriptorSet {
        var pool_to_use = self.getPool(device);
        var ai = vk.DescriptorSetAllocateInfo{
            .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
            .pNext = p_next,
            .descriptorPool = pool_to_use,
            .descriptorSetCount = 1,
            .pSetLayouts = &layout,
        };

        var ds: vk.DescriptorSet = undefined;

        checkVk(vk.AllocateDescriptorSets(device, &ai, &ds)) catch |e| {
            switch (e) {
                error.ErrorOutOfPoolMemory, error.ErrorFragmentedPool => {
                    self.full_pools.append(self.allocator, pool_to_use) catch @panic("OOM");
                    pool_to_use = self.getPool(device);
                    ai.descriptorPool = pool_to_use;
                    checkVk(vk.AllocateDescriptorSets(device, &ai, &ds)) catch @panic("failed on second try of allocating descriptor set");
                },
                else => @panic("encountered unexpected error when allocating descriptor set"),
            }
        };

        self.ready_pools.append(self.allocator, pool_to_use) catch @panic("OOM");
        return ds;
    }

    pub fn getPool(self: *Self, device: vk.Device) vk.DescriptorPool {
        var new_pool: vk.DescriptorPool = undefined;

        if (self.ready_pools.items.len != 0)
            new_pool = self.ready_pools.pop().?
        else
            new_pool = self.createPool(device);

        return new_pool;
    }

    pub fn createPool(self: *Self, device: vk.Device) vk.DescriptorPool {
        const pool_sizes: []vk.DescriptorPoolSize = self.allocator.alloc(vk.DescriptorPoolSize, self.ratios.len) catch @panic("out of memory");
        defer self.allocator.free(pool_sizes);
        for (pool_sizes, 0..) |*pool, i| {
            pool.type = self.ratios[i].typ;
            pool.descriptorCount = @intFromFloat(self.ratios[i].ratio * @as(f32, @floatFromInt(self.sets_per_pool)));
        }

        const ci = vk.DescriptorPoolCreateInfo{
            .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
            .flags = 0,
            .maxSets = self.sets_per_pool,
            .poolSizeCount = @as(u32, @intCast(pool_sizes.len)),
            .pPoolSizes = pool_sizes.ptr,
        };

        var new_pool: vk.DescriptorPool = undefined;

        checkVk(vk.CreateDescriptorPool(device, &ci, self.vk_alloc_cbs, &new_pool)) catch @panic("failed to create a new descriptor pool");

        return new_pool;
    }
};

pub const Writer = struct {
    allocator: std.mem.Allocator,
    buffer_infos: std.ArrayList(vk.DescriptorBufferInfo),
    image_infos: std.ArrayList(vk.DescriptorImageInfo),
    writes: std.ArrayList(vk.WriteDescriptorSet),

    const Self = @This();

    pub fn init(a: std.mem.Allocator) std.mem.Allocator.Error!Self {
        return .{
            .allocator = a,
            .buffer_infos = try std.ArrayList(vk.DescriptorBufferInfo).initCapacity(a, 32),
            .image_infos = try std.ArrayList(vk.DescriptorImageInfo).initCapacity(a, 32),
            .writes = try std.ArrayList(vk.WriteDescriptorSet).initCapacity(a, 32),
        };
    }

    pub fn deinit(self: *Self, a: std.mem.Allocator) void {
        self.buffer_infos.deinit(a);
        self.image_infos.deinit(a);
        self.writes.deinit(a);
    }

    pub fn updateSet(self: *Self, device: vk.Device, set: vk.DescriptorSet) void {
        for (0..self.writes.items.len) |i| {
            self.writes.items[i].dstSet = set;
        }

        vk.UpdateDescriptorSets(device, @as(u32, @intCast(self.writes.items.len)), self.writes.items.ptr, 0, null);
    }

    pub fn writeBuffer(
        self: *Self,
        a: std.mem.Allocator,
        binding: u32,
        buffer: vk.Buffer,
        size: u64,
        offset: u64,
        typ: vk.DescriptorType,
    ) void {
        self.buffer_infos.append(a, vk.DescriptorBufferInfo{
            .buffer = buffer,
            .offset = offset,
            .range = size,
        }) catch @panic("out of memory");

        const write = vk.WriteDescriptorSet{
            .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstBinding = binding,
            .dstSet = null,
            .descriptorCount = 1,
            .descriptorType = typ,
            .pBufferInfo = &self.buffer_infos.items[self.buffer_infos.items.len - 1],
        };
        self.writes.append(a, write) catch @panic("out of memory");
    }

    pub fn writeImage(
        self: *Self,
        a: std.mem.Allocator,
        binding: u32,
        image: vk.ImageView,
        sampler: vk.Sampler,
        layout: vk.ImageLayout,
        typ: vk.DescriptorType,
    ) void {
        self.image_infos.append(a, vk.DescriptorImageInfo{
            .sampler = sampler,
            .imageView = image,
            .imageLayout = layout,
        }) catch @panic("out of memory");

        const write = vk.WriteDescriptorSet{
            .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
            .dstBinding = binding,
            .dstSet = null,
            .descriptorCount = 1,
            .descriptorType = typ,
            .pImageInfo = &self.image_infos.items[self.image_infos.items.len - 1],
        };
        self.writes.append(a, write) catch @panic("out of memory");
    }
};

pub const LayoutBuilder = struct {
    bindings: std.ArrayList(vk.DescriptorSetLayoutBinding),

    const Self = @This();

    pub fn init(a: std.mem.Allocator) Self {
        return .{
            .bindings = std.ArrayList(vk.DescriptorSetLayoutBinding).initCapacity(a, 64) catch @panic("out of memory"),
        };
    }

    pub fn deinit(self: *Self, a: std.mem.Allocator) void {
        self.bindings.deinit(a);
    }

    pub fn addBinding(self: *Self, a: std.mem.Allocator, binding: u32, typ: vk.DescriptorType, stage_flags: vk.ShaderStageFlags) void {
        const newbind = vk.DescriptorSetLayoutBinding{
            .binding = binding,
            .stageFlags = stage_flags,
            .descriptorCount = 1,
            .descriptorType = typ,
        };

        self.bindings.append(a, newbind) catch @panic("out of memory");
    }

    pub fn clear(self: *Self) void {
        self.bindings.clearRetainingCapacity();
    }

    pub fn build(
        self: *Self,
        device: vk.Device,
        // shader_stages: vk.ShaderStageFlags,
        p_next: ?*const anyopaque,
        flags: vk.DescriptorSetLayoutCreateFlags,
        vk_alloc_cbs: ?*vk.AllocationCallbacks,
    ) vk.DescriptorSetLayout {
        // for (self.bindings.items) |*b| {
        //     b.stageFlags |= shader_stages;
        // }
        const ci =
            vk.DescriptorSetLayoutCreateInfo{
                .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
                .pNext = p_next,
                .pBindings = self.bindings.items.ptr,
                .bindingCount = @intCast(self.bindings.items.len),
                .flags = flags,
            };

        var set: vk.DescriptorSetLayout = undefined;
        checkVk(vk.CreateDescriptorSetLayout(device, &ci, vk_alloc_cbs, &set)) catch @panic("failed to create descriptor set layout");

        return set;
    }
};
