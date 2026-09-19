const std = @import("std");
const core = @import("../root.zig");
const log = std.log.scoped(.Physics);
const box3D = core.clibs.box3D;

world: box3D.WorldId,
debug: ?Debug,
debug_pipeline: ?core.engine.graphics_pipelines.PhysicsDebugPipeline,

const Debug = struct {
    const DrawShapeFcn = *const fn (?*anyopaque, box3D.WorldTransform, box3D.HexColor, ?*anyopaque) callconv(.c) bool;
    const DrawSegmentFcn = *const fn (box3D.Pos, box3D.Pos, box3D.HexColor, ?*anyopaque) callconv(.c) void;
    const DrawTransformFcn = *const fn (box3D.WorldTransform, ?*anyopaque) callconv(.c) void;
    const DrawPointFcn = *const fn (box3D.Pos, f32, box3D.HexColor, ?*anyopaque) callconv(.c) void;
    const DrawSphereFcn = *const fn (box3D.Pos, f32, box3D.HexColor, f32, ?*anyopaque) callconv(.c) void;
    const DrawCapsuleFcn = *const fn (box3D.Pos, box3D.Pos, f32, box3D.HexColor, f32, ?*anyopaque) callconv(.c) void;
    const DrawBoundsFcn = *const fn (box3D.AABB, box3D.HexColor, ?*anyopaque) callconv(.c) void;
    const DrawBoxFcn = *const fn (box3D.Vec3, box3D.WorldTransform, box3D.HexColor, ?*anyopaque) callconv(.c) void;
    const DrawStringFcn = *const fn (box3D.Pos, [*:0]const u8, box3D.HexColor, ?*anyopaque) callconv(.c) void;

    // b3_debug: box3D.DebugDraw,

    lines: std.ArrayListUnmanaged(DebugLine) = .empty,
    allocator: std.mem.Allocator,

    const DebugLine = struct {
        start: core.lib.math.Vec3,
        end: core.lib.math.Vec3,
        color: u32,
    };

    pub fn reset(self: *@This()) void {
        self.lines.clearRetainingCapacity();
    }

    pub fn addLine(self: *@This(), p1: core.lib.math.Vec3, p2: core.lib.math.Vec3, color: u32) void {
        self.lines.append(self.allocator, .{ .start = p1, .end = p2, .color = color }) catch {};
    }

    fn drawSegment(p1: box3D.Pos, p2: box3D.Pos, color: box3D.HexColor, context: ?*anyopaque) callconv(.c) void {
        const self: *Debug = @ptrCast(@alignCast(context.?));
        self.addLine(
            core.lib.math.Vec3.make(p1.x, p1.y, p1.z),
            core.lib.math.Vec3.make(p2.x, p2.y, p2.z),
            color,
        );
    }

    fn drawBox(extents: box3D.Vec3, transform: box3D.WorldTransform, color: box3D.HexColor, context: ?*anyopaque) callconv(.c) void {
        const self: *Debug = @ptrCast(@alignCast(context.?));
        _ = self;
        _ = extents;
        _ = transform;
        _ = color;
        // ... build/add lines as before
    }

    // Build the actual b3DebugDraw struct to hand to box3d, pointing at `self`.
    pub fn makeDebugDraw(self: *@This()) box3D.DebugDraw {
        var draw = box3D.DefaultDebugDraw();
        draw.DrawSegmentFcn = drawSegment;
        draw.DrawBoxFcn = drawBox;
        draw.drawShapes = true;
        draw.context = @ptrCast(self);
        return draw;
    }
};

pub const CreateInfo = struct {
    pd: ?core.engine.graphics_pipelines.PhysicsDebugPipeline.Description = null,
    debug: ?Debug = null,
};

pub fn init(ci: CreateInfo, alloc_cbs: ?*core.clibs.vk.AllocationCallbacks) @This() {
    var world_def = box3D.DefaultWorldDef();
    world_def.gravity = .{
        .x = 0.0,
        .y = 0.0,
        .z = -10.0,
    };
    const world = box3D.CreateWorld(&world_def);
    const pipeline = if (ci.debug != null) core.engine.graphics_pipelines.PhysicsDebugPipeline.init(ci.pd.?, alloc_cbs) else null;
    return .{
        .world = world,
        .debug = ci.debug,
        .debug_pipeline = pipeline,
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

    if (self.debug) |*dbg| {
        dbg.reset(); // clears self.lines from last frame

        var draw = dbg.makeDebugDraw(); // builds b3DebugDraw with context = self
        box3D.World_Draw(self.world, &draw, 0);
    }
}
