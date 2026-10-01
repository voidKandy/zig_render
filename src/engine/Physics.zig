const std = @import("std");
const core = @import("../root.zig");
const log = std.log.scoped(.Physics);
const box3d = core.clibs.box3d;
const box3d_usage = core.bindings.box3d_usage;

world: box3d.WorldId,
debug_ctx: ?*DebugContext,
meshes: std.StringHashMapUnmanaged(*box3d.MeshData) = .empty,

pub fn init(debug_ci: ?DebugContext.CreateInfo) std.mem.Allocator.Error!@This() {
    var world_def = box3d.DefaultWorldDef();
    world_def.gravity = .{
        .x = 0.0,
        .y = 0.0,
        .z = -10.0,
    };
    var self = @This(){
        .world = undefined,
        .debug_ctx = null,
    };

    if (debug_ci) |ci| {
        const ctx = try ci.allocator.create(DebugContext);
        ctx.* = try DebugContext.init(ci.allocator);
        self.debug_ctx = ctx;
        world_def.createDebugShape = DebugContext.DEBUG_SHAPE_FUNCTIONS.create_debug_shape;
        world_def.destroyDebugShape = DebugContext.DEBUG_SHAPE_FUNCTIONS.destroy_debug_shape;
        world_def.userDebugShapeContext = @ptrCast(ctx);
    }

    self.world = box3d.CreateWorld(&world_def);

    return self;
}

pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
    box3d.DestroyWorld(self.world);

    var iter = self.meshes.valueIterator();
    while (iter.next()) |mesh|
        box3d.DestroyMesh(mesh.*);

    self.meshes.deinit(a);

    if (self.debug_ctx) |ctx| {
        ctx.vertices.deinit(ctx.allocator);
        ctx.allocator.destroy(ctx);
    }
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
}

pub fn update(self: *@This(), world: *core.engine.world.GameWorld) void {
    const _60hz = 1.0 / 60.0;
    var debug = if (self.debug_ctx) |ctx| ctx.makeDebugDraw() else null;

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

    if (debug) |*dbg| {
        box3d.World_Draw(self.world, dbg, std.math.maxInt(u64));
    }
}

pub const DebugContext = struct {
    const CreateInfo = struct {
        allocator: std.mem.Allocator,
    };

    vertices: std.ArrayListUnmanaged(core.engine.Renderer.PhysicsDebug.DebugVertex),
    allocator: std.mem.Allocator,

    pub fn init(a: std.mem.Allocator) std.mem.Allocator.Error!@This() {
        return .{
            .vertices = try .initCapacity(a, core.engine.Renderer.PhysicsDebug.MAX_DEBUG_LINES),
            .allocator = a,
        };
    }

    pub fn reset(self: *@This()) void {
        self.vertices.clearRetainingCapacity();
    }

    pub fn addLine(
        self: *@This(),
        p1: box3d.Vec3,
        p2: box3d.Vec3,
        color: box3d.HexColor,
    ) void {
        self.vertices.appendAssumeCapacity(.{
            .position = box3d_usage.toCoreVec3(p1),
            .color = box3d_usage.unpackHexColor(color),
        });

        self.vertices.appendAssumeCapacity(.{
            .position = box3d_usage.toCoreVec3(p2),
            .color = box3d_usage.unpackHexColor(color),
        });
    }

    pub fn makeDebugDraw(self: *@This()) box3d.DebugDraw {
        self.reset();
        var draw = box3d.DefaultDebugDraw();

        draw.DrawShapeFcn = DEBUG_DRAW_FUNCTIONS.draw_shape;
        draw.DrawSegmentFcn = DEBUG_DRAW_FUNCTIONS.draw_segment;
        draw.DrawTransformFcn = DEBUG_DRAW_FUNCTIONS.draw_transform;
        draw.DrawPointFcn = DEBUG_DRAW_FUNCTIONS.draw_point;
        draw.DrawSphereFcn = DEBUG_DRAW_FUNCTIONS.draw_sphere;
        draw.DrawCapsuleFcn = DEBUG_DRAW_FUNCTIONS.draw_capsule;
        draw.DrawBoundsFcn = DEBUG_DRAW_FUNCTIONS.draw_bounds;
        draw.DrawBoxFcn = DEBUG_DRAW_FUNCTIONS.draw_box;
        draw.DrawStringFcn = DEBUG_DRAW_FUNCTIONS.draw_string;

        draw.drawShapes = true;
        draw.drawBounds = true;
        draw.drawingBounds = .{
            .lowerBound = .{
                .x = -100.0,
                .y = -100.0,
                .z = -100.0,
            },
            .upperBound = .{
                .x = 100.0,
                .y = 100.0,
                .z = 100.0,
            },
        };

        draw.context = @ptrCast(self);
        return draw;
    }

    const DebugMeshLines = struct {
        lines: []box3d.Vec3,
    };

    const DEBUG_SHAPE_FUNCTIONS: box3d_usage.DebugShapeFunctions = .{
        .create_debug_shape = struct {
            pub fn call(debug_shape: ?*const box3d.DebugShape, context: ?*anyopaque) callconv(.c) ?*anyopaque {
                const ds = debug_shape.?;
                if (ds.type != box3d.mesh_shape) return null; // let boxes/spheres/capsules keep using their typed callbacks

                const ctx: *DebugContext = @ptrCast(@alignCast(context.?));
                const mesh_data = ds.unnamed_0.mesh[0].data;

                const verts = box3d.GetMeshVertices(mesh_data);
                const tris = box3d.GetMeshTriangles(mesh_data);
                const tri_count = mesh_data[0].triangleCount;

                // Build and own a flat line-list (two endpoints per triangle edge) once,
                // in LOCAL space — DrawShapeFcn gets the current world transform separately
                // every frame, so don't bake a transform in here.
                var lines = std.ArrayListUnmanaged(box3d.Vec3).initCapacity(ctx.allocator, @intCast(tri_count * 6)) catch return null;

                for (0..@intCast(tri_count)) |i| {
                    const tri = tris[i];
                    const v0 = verts[@intCast(tri.index1)];
                    const v1 = verts[@intCast(tri.index2)];
                    const v2 = verts[@intCast(tri.index3)];
                    lines.appendSliceAssumeCapacity(&.{ v0, v1, v1, v2, v2, v0 });
                }

                const owned = lines.toOwnedSlice(ctx.allocator) catch return null;
                const boxed = ctx.allocator.create(DebugMeshLines) catch return null;
                boxed.* = .{ .lines = owned };
                return @ptrCast(boxed);
            }
        }.call,

        .destroy_debug_shape = struct {
            pub fn call(user_shape: ?*anyopaque, context: ?*anyopaque) callconv(.c) void {
                const ctx: *DebugContext = @ptrCast(@alignCast(context.?));
                const boxed: *DebugMeshLines = @ptrCast(@alignCast(user_shape.?));
                ctx.allocator.free(boxed.lines);
                ctx.allocator.destroy(boxed);
            }
        }.call,
    };

    const DEBUG_DRAW_FUNCTIONS: box3d_usage.DebugDrawFunctions = .{
        .draw_shape = struct {
            fn call(shape: ?*anyopaque, transform: box3d.WorldTransform, color: box3d.HexColor, context: ?*anyopaque) callconv(.c) void {
                const debug: *DebugContext = @ptrCast(@alignCast(context.?));
                const boxed: *DebugMeshLines = @ptrCast(@alignCast(shape.?));

                var i: usize = 0;
                while (i < boxed.lines.len) : (i += 2) {
                    const p1 = box3d.TransformWorldPoint(transform, boxed.lines[i]);
                    const p2 = box3d.TransformWorldPoint(transform, boxed.lines[i + 1]);
                    debug.addLine(p1, p2, color);
                }
            }
        }.call,

        .draw_bounds = struct {
            fn call(aabb: box3d.AABB, color: box3d.HexColor, context: ?*anyopaque) callconv(.c) void {
                const debug: *DebugContext = @ptrCast(@alignCast(context.?));

                const min = aabb.lowerBound;
                const max = aabb.upperBound;

                const corners = [_]box3d.Pos{
                    .{ .x = min.x, .y = min.y, .z = min.z },
                    .{ .x = max.x, .y = min.y, .z = min.z },
                    .{ .x = max.x, .y = max.y, .z = min.z },
                    .{ .x = min.x, .y = max.y, .z = min.z },

                    .{ .x = min.x, .y = min.y, .z = max.z },
                    .{ .x = max.x, .y = min.y, .z = max.z },
                    .{ .x = max.x, .y = max.y, .z = max.z },
                    .{ .x = min.x, .y = max.y, .z = max.z },
                };

                const edges = [_][2]usize{
                    // Bottom
                    .{ 0, 1 },
                    .{ 1, 2 },
                    .{ 2, 3 },
                    .{ 3, 0 },

                    // Top
                    .{ 4, 5 },
                    .{ 5, 6 },
                    .{ 6, 7 },
                    .{ 7, 4 },

                    // Vertical
                    .{ 0, 4 },
                    .{ 1, 5 },
                    .{ 2, 6 },
                    .{ 3, 7 },
                };

                for (edges) |edge| {
                    debug.addLine(
                        corners[edge[0]],
                        corners[edge[1]],
                        color,
                    );
                }
            }
        }.call,
    };
};
