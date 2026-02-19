const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.ResourceManager);
const texs = @import("textures.zig");
const vma = @import("clibs.zig").vma;
const vk = @import("clibs.zig").vk;
const vma_usage = @import("vma_usage.zig");
const mesh_mod = @import("mesh.zig");
const IdentifierManager = @import("ecs.zig").IdentifierManager;

pub const Type = enum {
    mesh3D,
    sampler,
    image,
    buffer,
};

pub const ResourceID = union(Type) {
    mesh3D: u32,
    sampler: u32,
    image: u32,
    buffer: u32,
};

pub const Resource = union(Type) {
    mesh3D: mesh_mod.Mesh3D,
    sampler: vk.Sampler,
    image: vma_usage.AllocatedImage,
    buffer: vma_usage.AllocatedBuffer,
};

pub const ResourcePtr = union(Type) {
    mesh3D: *mesh_mod.Mesh3D,
    sampler: *vk.Sampler,
    image: *vma_usage.AllocatedImage,
    buffer: *vma_usage.AllocatedBuffer,
};

mesh3D_manager: IdentifierManager(mesh_mod.Mesh3D, 48),
// texture_manager: IdentifierManager(texs.Texture, 48),
sampler_manager: IdentifierManager(vk.Sampler, 48),
image_manager: IdentifierManager(vma_usage.AllocatedImage, 48),
buffer_manager: IdentifierManager(vma_usage.AllocatedBuffer, 48),
const Self = @This();

pub fn init(a: Allocator) (std.posix.OpenError || Allocator.Error)!Self {
    return Self{
        .mesh3D_manager = try .init(a),
        .image_manager = try .init(a),
        .sampler_manager = try .init(a),
        .buffer_manager = try .init(a),
    };
}

/// this function exposes an issue with IdentifierManager where if
/// type T has extra cleanup that needs to be done, it will not be done
/// This might be fine
pub fn deinit(self: *Self, a: Allocator, vma_a: vma.Allocator, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
    for (self.mesh3D_manager.data) |mesh_opt| if (mesh_opt) |mesh|
        mesh.deinit(a, vma_a)
    else
        break;
    self.mesh3D_manager.deinit(a);

    // for (self.texture_manager.data) |tx_opt| if (tx_opt) |tx| {
    //     vk.DestroyImageView(device, tx.image_view, alloc_cbs);
    //     vma.DestroyImage(vma_a, tx.image.image, tx.image.allocation);
    // } else break;
    // self.texture_manager.deinit(a);

    for (self.sampler_manager.data) |sampler_opt| if (sampler_opt) |sampler| {
        vk.DestroySampler(device, sampler, alloc_cbs);
    } else break;
    self.sampler_manager.deinit(a);

    for (self.image_manager.data) |img_opt| if (img_opt) |img| {
        img.deinit(vma_a, device, alloc_cbs);
    } else break;
    self.image_manager.deinit(a);

    for (self.buffer_manager.data) |buf_opt| if (buf_opt) |buf| {
        vma.DestroyBuffer(vma_a, buf.buffer, buf.allocation);
    } else break;
    self.buffer_manager.deinit(a);
}

pub fn getId(self: Self, t: Type, idx: usize) ?ResourceID {
    return switch (t) {
        .mesh3D => .{ .mesh3D = self.mesh3D_manager.getId(idx) orelse return null },
        // .texture => .{ .texture = self.texture_manager.getId(idx) orelse return null },
        .sampler => .{ .sampler = self.sampler_manager.getId(idx) orelse return null },
        .image => .{ .image = self.image_manager.getId(idx) orelse return null },
        .buffer => .{ .buffer = self.buffer_manager.getId(idx) orelse return null },
    };
}

pub fn insert(self: *Self, insrt: Resource) Allocator.Error!u32 {
    switch (insrt) {
        .mesh3D => |mesh| {
            const id, _ = try self.mesh3D_manager.register(mesh);
            return id;
        },
        // .texture => |tx| {
        //     const id, _ = try self.texture_manager.register(tx);
        //     return id;
        // },
        .sampler => |smp| {
            const id, _ = try self.sampler_manager.register(smp);
            return id;
        },
        .image => |img| {
            const id, _ = try self.image_manager.register(img);
            return id;
        },
        .buffer => |buf| {
            const id, _ = try self.buffer_manager.register(buf);
            return id;
        },
    }
}

pub fn query(self: Self, qu: ResourceID) ?Resource {
    return switch (qu) {
        .mesh3D => |id| .{ .mesh3D = self.mesh3D_manager.getData(id) orelse return null },
        // .texture => |id| .{ .texture = self.texture_manager.getData(id) orelse return null },
        .sampler => |id| .{ .sampler = self.sampler_manager.getData(id) orelse return null },
        .image => |id| .{ .image = self.image_manager.getData(id) orelse return null },
        .buffer => |id| .{ .buffer = self.buffer_manager.getData(id) orelse return null },
    };
}

pub fn queryPtr(self: *Self, qu: ResourceID) ?ResourcePtr {
    switch (qu) {
        .mesh3D => |id| return .{ .mesh3D = try self.mesh3D_manager.getDataPtr(id) },
        // .texture => |id| return .{ .texture = try self.texture_manager.getDataPtr(id) },
        .sampler => |id| return .{ .sampler = try self.sampler_manager.getDataPtr(id) },
        .image => |id| return .{ .image = try self.image_manager.getDataPtr(id) },
        .buffer => |id| return .{ .buffer = try self.buffer_manager.getDataPtr(id) },
    }
}
