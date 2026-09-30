const std = @import("std");
const core = @import("../root.zig");
const log = std.log.scoped(.Physics);
const box3d = core.clibs.box3d;
const box3d_usage = core.bindings.box3d_usage;

world: box3d.WorldId,
meshes: std.StringHashMapUnmanaged(*box3d.MeshData) = .empty,

pub fn init() @This() {
    var world_def = box3d.DefaultWorldDef();
    world_def.gravity = .{
        .x = 0.0,
        .y = 0.0,
        .z = -10.0,
    };
    const world = box3d.CreateWorld(&world_def);
    return .{
        .world = world,
    };
}

pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
    box3d.DestroyWorld(self.world);

    var iter = self.meshes.valueIterator();
    while (iter.next()) |mesh|
        box3d.DestroyMesh(mesh.*);

    self.meshes.deinit(a);
}

pub fn createMeshes(
    self: *@This(),
    a: std.mem.Allocator,
    _: *core.engine.world.GameWorld,
    meshes: *const core.resources.Meshes3D,
) std.mem.Allocator.Error!void {
    var iter = meshes.mesh_indices.iterator();
    while (iter.next()) |entry| {
        const idx = entry.value_ptr.*;
        const name = entry.key_ptr.*;

        const result = try self.meshes.getOrPut(a, name);
        if (result.found_existing) continue;
        const b3d_mesh: *box3d.MeshData = &(try box3d_usage.createMesh(a, meshes, idx))[0];
        result.value_ptr.* = b3d_mesh;
    }

    // var query = world.queryEntities(.{ .is = .{
    //     .rule = .at_least,
    //     .sig = .initMany(&.{ .rigid_body, .mesh3D, .world_transform }),
    // } });

    // var meshes_need_colliders = std.AutoHashMapUnmanaged(usize, void).empty;
    // while (query.next()) |ent| {
    //     const mesh: *core.engine.world.MaterialMesh3D = (ent.accessComponentPtr(.mesh3D) catch @panic("No transform?"))
    //         .mesh3D;
    //     try meshes_need_colliders.put(a, mesh.mesh_index, {});
    // }

    // var mesh_idx_iter = meshes_need_colliders.keyIterator();
    // while (mesh_idx_iter.next()) |idx| {
    //     const name = meshes.mesh_names_reverse_lookup.get(idx.*).?;
    //     const result = try self.meshes.getOrPut(a, name);
    //     if (result.found_existing) continue;
    //     const b3d_mesh: *box3d.MeshData = &(try box3d_usage.createMesh(a, meshes, idx.*))[0];
    //     result.value_ptr.* = b3d_mesh;
    // }
}

pub fn update(self: *@This(), world: *core.engine.world.GameWorld, debug: ?*box3d.DebugDraw) void {
    const _60hz = 1.0 / 60.0;
    box3d.World_Step(self.world, _60hz, 4);
    const events = box3d.World_GetBodyEvents(self.world);
    if (events.moveCount == 0) return;

    for (events.moveEvents[0..@intCast(events.moveCount)]) |e| {
        const ent_id: *const u32 = @ptrCast(@alignCast(e.userData.?));
        const physics_transform: box3d.WorldTransform = e.transform;

        const ent = world.entityHandle(ent_id.*) catch @panic("NO ENTITY??");
        _ = ent.accessComponent(.rigid_body) catch @panic("No body?");
        var transform = (ent.accessComponentPtr(.world_transform) catch @panic("No transform?"))
            .world_transform;

        const pos = physics_transform.p;
        const rot = physics_transform.q;

        const angle = 2.0 * std.math.acos(rot.s);
        const sin_half_angle = @sqrt(1.0 - rot.s * rot.s);

        const axis = if (sin_half_angle < 0.0001)
            core.lib.math.Vec3.RIGHT
        else
            core.lib.math.Vec3{
                .x = rot.v.x / sin_half_angle,
                .y = rot.v.y / sin_half_angle,
                .z = rot.v.z / sin_half_angle,
            };

        transform.matrix =
            core.lib.math.Mat4.IDENTITY
                .translate(.{
                    .x = pos.x,
                    .y = pos.y,
                    .z = pos.z,
                })
                .rotate(axis, angle);
    }

    if (debug) |dbg| {
        box3d.World_Draw(self.world, dbg, std.math.maxInt(u64));
    }
}
