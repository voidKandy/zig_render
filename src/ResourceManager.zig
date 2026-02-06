const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.ResourceManager);
const texs = @import("textures.zig");
const vma = @import("clibs.zig").vma;
const vk = @import("clibs.zig").vk;
const vma_usage = @import("vma_usage.zig");
const mesh_mod = @import("mesh.zig");

pub const Type = enum {
    mesh3D,
    texture,
    sampler,
    image,
    buffer,
    // render_pass,
};

pub const ResourceID = union(Type) {
    mesh3D: u32,
    texture: u32,
    sampler: u32,
    image: u32,
    buffer: u32,
};

pub const Resource = union(Type) {
    mesh3D: mesh_mod.Mesh3D,
    texture: texs.Texture,
    sampler: vk.Sampler,
    image: vma_usage.AllocatedImage,
    buffer: vma_usage.AllocatedBuffer,
};

pub const ResourcePtr = union(Type) {
    mesh3D: *mesh_mod.Mesh3D,
    texture: *texs.Texture,
    sampler: *vk.Sampler,
    image: *vma_usage.AllocatedImage,
    buffer: *vma_usage.AllocatedBuffer,
};

mesh3D_manager: IdentifierManager(mesh_mod.Mesh3D, 48),
texture_manager: IdentifierManager(texs.Texture, 48),
sampler_manager: IdentifierManager(vk.Sampler, 48),
image_manager: IdentifierManager(vma_usage.AllocatedImage, 48),
buffer_manager: IdentifierManager(vma_usage.AllocatedBuffer, 48),
const Self = @This();

pub fn init(a: Allocator) (std.posix.OpenError || Allocator.Error)!Self {
    return Self{
        .mesh3D_manager = try .init(a),
        .texture_manager = try .init(a),
        .image_manager = try .init(a),
        .sampler_manager = try .init(a),
        .buffer_manager = try .init(a),
        // .render_pass_manager = try .init(a),
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

    for (self.texture_manager.data) |tx_opt| if (tx_opt) |tx| {
        vk.DestroyImageView(device, tx.image_view, alloc_cbs);
        vma.DestroyImage(vma_a, tx.image.image, tx.image.allocation);
    } else break;
    self.texture_manager.deinit(a);

    for (self.sampler_manager.data) |sampler_opt| if (sampler_opt) |sampler| {
        vk.DestroySampler(device, sampler, alloc_cbs);
    } else break;
    self.sampler_manager.deinit(a);

    for (self.image_manager.data) |img_opt| if (img_opt) |img| {
        vma.DestroyImage(vma_a, img.image, img.allocation);
        vk.DestroyImageView(device, img.view, alloc_cbs);
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
        .texture => .{ .texture = self.texture_manager.getId(idx) orelse return null },
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
        .texture => |tx| {
            const id, _ = try self.texture_manager.register(tx);
            return id;
        },
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
        .texture => |id| .{ .texture = self.texture_manager.getData(id) orelse return null },
        .sampler => |id| .{ .sampler = self.sampler_manager.getData(id) orelse return null },
        .image => |id| .{ .image = self.image_manager.getData(id) orelse return null },
        .buffer => |id| .{ .buffer = self.buffer_manager.getData(id) orelse return null },
    };
}

pub fn queryPtr(self: *Self, qu: ResourceID) ?ResourcePtr {
    switch (qu) {
        .mesh3D => |id| return .{ .mesh3D = try self.mesh3D_manager.getDataPtr(id) },
        .texture => |id| return .{ .texture = try self.texture_manager.getDataPtr(id) },
        .sampler => |id| return .{ .sampler = try self.sampler_manager.getDataPtr(id) },
        .image => |id| return .{ .image = try self.image_manager.getDataPtr(id) },
        .buffer => |id| return .{ .buffer = try self.buffer_manager.getDataPtr(id) },
    }
}

fn IdentifierManager(
    comptime T: type,
    MAX: comptime_int,
) type {
    return struct {
        const IdentifierNode = struct {
            node: std.DoublyLinkedList.Node = .{},
            id: u32,
        };
        const IdQueue = std.DoublyLinkedList;
        const Manager = @This();

        available_ids: std.DoublyLinkedList,
        index_map: std.AutoHashMap(u32, usize),
        identifier_map: std.AutoHashMap(usize, *IdentifierNode),
        count: usize,
        /// Maintains a *tightly packed* array of Data
        data: [MAX]?T = blk: {
            var all: [MAX]?T = undefined;
            @memset(&all, null);
            break :blk all;
        },

        /// requires the same allocator be passed as with `init`
        fn deinit(self: *@This(), allocator: Allocator) void {
            defer self.index_map.deinit();
            var keys = self.identifier_map.keyIterator();
            while (keys.next()) |k| {
                const kv = self.identifier_map.fetchRemove(k.*) orelse unreachable;
                allocator.destroy(kv.value);
            }
            defer self.identifier_map.deinit();
            while (self.available_ids.pop()) |n|
                allocator.destroy(@as(*IdentifierNode, @fieldParentPtr("node", n)));
        }

        fn init(allocator: Allocator) (std.posix.OpenError || Allocator.Error)!Manager {
            var prng = std.Random.DefaultPrng.init(blk: {
                var seed: u64 = undefined;
                try std.posix.getrandom(std.mem.asBytes(&seed));
                break :blk seed;
            });
            const rand = prng.random();

            var available_ids = std.DoublyLinkedList{};

            for (0..MAX) |_| {
                const node = try allocator.create(IdentifierNode);
                node.* = .{
                    .id = rand.int(u32),
                };
                available_ids.append(&node.node);
            }

            const idx_map = std.AutoHashMap(u32, usize).init(allocator);
            const ent_map = std.AutoHashMap(usize, *IdentifierNode).init(allocator);
            return Manager{
                .available_ids = available_ids,
                .index_map = idx_map,
                .identifier_map = ent_map,
                .count = 0,
            };
        }

        /// Returns the identifier & index of registered entity
        fn register(
            self: *Manager,
            data: T,
        ) Allocator.Error!struct { u32, usize } {
            const id_node: *IdentifierNode = @fieldParentPtr("node", self.available_ids.pop() orelse @panic("Identifier not available"));
            try self.index_map.put(id_node.id, self.count);
            try self.identifier_map.put(self.count, id_node);
            self.data[self.count] = data;
            self.count += 1;
            return .{ id_node.id, self.count - 1 };
        }

        fn lastRegistered(self: Manager) ?struct { u32, usize } {
            const dif = MAX - self.available_ids.len();
            if (dif == 0) return null;
            const idx = dif - 1;
            const node = self.identifier_map.get(idx) orelse return null;
            return .{ node.id, idx };
        }

        fn remove(self: *Manager, id: u32) (error{NotPresent} || Allocator.Error)!void {
            const index = (self.index_map.fetchRemove(id) orelse return error.NotPresent).value;
            const node = (self.identifier_map.fetchRemove(index) orelse @panic("No node for index?")).value;
            if (self.lastRegistered()) |last_reg| {
                if (last_reg.@"0" != id) {
                    const last_reg_kv = self.identifier_map.fetchRemove(last_reg.@"1") orelse @panic("No node for last registered?");
                    const last_reg_node = last_reg_kv.value;
                    const last_data = self.getData(last_reg.@"0") orelse @panic("No signature for last registered?");
                    try self.index_map.put(last_reg.@"0", index);
                    try self.identifier_map.put(index, last_reg_node);
                    self.data[index] = last_data;
                    self.data[last_reg.@"1"] = null;
                }
            }

            self.available_ids.append(&node.node);
            self.count -= 1;

            return;
        }

        fn getId(self: Manager, idx: usize) ?u32 {
            return (self.identifier_map.get(idx) orelse return null).id;
        }

        fn getData(self: Manager, entity: u32) ?T {
            const idx = self.index_map.get(entity) orelse return null;
            return self.data[idx];
        }

        fn getDataPtr(self: *Manager, entity: u32) ?*T {
            const idx = self.index_map.get(entity) orelse return null;
            return &(self.data[idx] orelse return null);
        }
    };
}

test "register assigns ids and stores data" {
    const Manager = IdentifierManager(u8, 8);
    var m = try Manager.init(std.testing.allocator);
    defer m.deinit(std.testing.allocator);

    const a = try m.register(10);
    const b = try m.register(20);

    try std.testing.expectEqual(@as(usize, 2), m.count);
    try std.testing.expectEqual(@as(u8, 10), m.getData(a.@"0").?);
    try std.testing.expectEqual(@as(u8, 20), m.getData(b.@"0").?);
}

test "remove decreases count and moves data" {
    const Manager = IdentifierManager(u8, 8);
    var m = try Manager.init(std.testing.allocator);
    defer m.deinit(std.testing.allocator);

    const a = try m.register(1);
    const b = try m.register(2);

    try m.remove(a.@"0");

    try std.testing.expectEqual(@as(usize, 1), m.count);
    try std.testing.expect(m.getData(a.@"0") == null);
    try std.testing.expectEqual(@as(u8, 2), m.getData(b.@"0").?);
}

test "remove middle swaps last into hole" {
    const Manager = IdentifierManager(u8, 8);
    var m = try Manager.init(std.testing.allocator);
    defer m.deinit(std.testing.allocator);

    const a = try m.register(1);
    const b = try m.register(2);
    const c_ = try m.register(3);

    try m.remove(b.@"0");

    try std.testing.expectEqual(@as(usize, 2), m.count);
    try std.testing.expectEqual(@as(u8, 1), m.getData(a.@"0").?);
    try std.testing.expectEqual(@as(u8, 3), m.getData(c_.@"0").?);
}

test "ids are reused after removal" {
    const Manager = IdentifierManager(u8, 4);
    var m = try Manager.init(std.testing.allocator);
    defer m.deinit(std.testing.allocator);

    const a = try m.register(42);
    try m.remove(a.@"0");

    const b = try m.register(99);

    try std.testing.expectEqual(a.@"0", b.@"0");
    try std.testing.expectEqual(@as(u8, 99), m.getData(b.@"0").?);
}

test "lastRegistered returns last live element" {
    const Manager = IdentifierManager(u8, 8);
    var m = try Manager.init(std.testing.allocator);
    defer m.deinit(std.testing.allocator);

    _ = try m.register(1);
    const b = try m.register(2);

    const last = m.lastRegistered() orelse @panic("No last registered?");
    try std.testing.expectEqual(b.@"0", last.@"0");
    try std.testing.expectEqual(@as(usize, 1), last.@"1");
}

test "getDataPtr allows mutation" {
    const Manager = IdentifierManager(u8, 8);
    var m = try Manager.init(std.testing.allocator);
    defer m.deinit(std.testing.allocator);

    const id = try m.register(10);

    const ptr = m.getDataPtr(id.@"0") orelse unreachable;
    ptr.* = 42;

    try std.testing.expectEqual(@as(u8, 42), m.getData(id.@"0").?);
}

test "getDataPtr mutation persists across operations" {
    const Manager = IdentifierManager(u8, 8);
    var m = try Manager.init(std.testing.allocator);
    defer m.deinit(std.testing.allocator);

    const a = try m.register(1);
    const b = try m.register(2);

    const a_ptr = m.getDataPtr(a.@"0") orelse unreachable;
    a_ptr.* = 99;

    // unrelated removal
    try m.remove(b.@"0");

    try std.testing.expectEqual(@as(u8, 99), m.getData(a.@"0").?);
}
