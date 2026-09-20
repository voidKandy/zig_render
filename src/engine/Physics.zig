const std = @import("std");
const core = @import("../root.zig");
const log = std.log.scoped(.Physics);
const box3D = core.clibs.box3D;

world: box3D.WorldId,

pub fn init() @This() {
    var world_def = box3D.DefaultWorldDef();
    world_def.gravity = .{
        .x = 0.0,
        .y = 0.0,
        .z = -10.0,
    };
    const world = box3D.CreateWorld(&world_def);
    return .{
        .world = world,
    };
}

pub fn deinit(self: @This(), device: core.clibs.vk.Device, alloc_cbs: ?*core.clibs.vk.ALlocationCallbacks) void {
    box3D.DestroyWorld(self.world);
    if (self.debug_pipeline) |p| p.deinit(device, alloc_cbs);
}

pub fn update(self: *@This(), world: *core.engine.world.GameWorld) void {
    box3D.World_Step(self.world, 1.0 / 60.0, 4);

    var iter = world.queryEntities(.{ .is = .{ .rule = .at_least, .sig = .initMany(&.{ .rigid_body, .transform }) } });
    while (iter.next()) |ent| {
        const rigid_body = (ent.accessComponent(.rigid_body) catch @panic("No body?")).rigid_body;
        var transform = (ent.accessComponentPtr(.transform) catch @panic("No transform?")).transform;

        const position = box3D.Body_GetPosition(rigid_body.id);
        const rotation = box3D.Body_GetRotation(rigid_body.id);

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

    // if (self.debug) |*dbg| {
    //     dbg.reset(); // clears self.lines from last frame

    //     var draw = dbg.makeDebugDraw(); // builds b3DebugDraw with context = self
    //     box3D.World_Draw(self.world, &draw, 0);
    // }
}
