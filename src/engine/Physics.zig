const std = @import("std");
const core = @import("../root.zig");
const log = std.log.scoped(.Physics);
const box3d = core.clibs.box3d;

world: box3d.WorldId,

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

pub fn deinit(self: @This()) void {
    box3d.DestroyWorld(self.world);
}

pub fn update(self: *@This(), world: *core.engine.world.GameWorld, debug: ?*box3d.DebugDraw) void {
    const _60hz = 1.0 / 60.0;
    box3d.World_Step(self.world, _60hz, 4);

    var iter = world.queryEntities(.{ .is = .{ .rule = .at_least, .sig = .initMany(&.{ .rigid_body, .world_transform }) } });
    while (iter.next()) |ent| {
        const rigid_body = (ent.accessComponent(.rigid_body) catch @panic("No body?")).rigid_body;
        var transform = (ent.accessComponentPtr(.world_transform) catch @panic("No transform?")).world_transform;

        const position = box3d.Body_GetPosition(rigid_body.id);
        const rotation = box3d.Body_GetRotation(rigid_body.id);

        const angle = 2.0 * std.math.acos(rotation.s);
        const sin_half_angle = @sqrt(1.0 - rotation.s * rotation.s);

        const axis = if (sin_half_angle < 0.0001)
            core.lib.math.Vec3.RIGHT
        else
            core.lib.math.Vec3{
                .x = rotation.v.x / sin_half_angle,
                .y = rotation.v.y / sin_half_angle,
                .z = rotation.v.z / sin_half_angle,
            };

        transform.matrix =
            core.lib.math.Mat4.IDENTITY
                .translate(.{
                    .x = position.x,
                    .y = position.y,
                    .z = position.z,
                })
                .rotate(axis, angle);
    }

    if (debug) |dbg| {
        box3d.World_Draw(self.world, dbg, std.math.maxInt(u64));
    }
}
