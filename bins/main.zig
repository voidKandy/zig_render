const std = @import("std");
const log = std.log;
const core = @import("core");
const shared = @import("shared");
const vku = core.bindings.vulkan_usage;
const vma_usage = core.bindings.vma_usage;
const mesh_mod = core.lib.mesh;
const math_mod = core.lib.math;
const c = core.clibs;
const vk = c.vk;
const vma = c.vma;
const checkVk = vku.checkVk;
const sdl = c.sdl;
const VkError = vku.VkError;
const Vec2 = math_mod.Vec2;
const Vec3 = math_mod.Vec3;
const Vec4 = math_mod.Vec4;
const Mat4 = math_mod.Mat4;

pub const std_options = std.Options{
    .log_level = .debug,
};

const Engine = core.engine.Engine.EngineType(shared.SystemManager, shared.GameWorld);
const CoreEngine = core.engine.Engine;

pub fn main(init: std.process.Init) std.mem.Allocator.Error!void {
    var a = init.arena.allocator();

    var api_version: u32 = undefined;
    _ = vk.EnumerateInstanceVersion(&api_version);
    std.debug.print(
        "Runtime Vulkan version = {}.{}.{}\n",
        .{
            vk.API_VERSION_MAJOR(api_version),
            vk.API_VERSION_MINOR(api_version),
            vk.API_VERSION_PATCH(api_version),
        },
    );

    var global_mat = core.loaders.mtl.parseFile(a, init.io, "assets/globals.mtl") catch @panic("failed to load materials file");
    defer global_mat.deinit();
    var debug_mat = core.loaders.mtl.parseFile(a, init.io, "assets/debug.mtl") catch @panic("failed to load materials file");
    defer debug_mat.deinit();

    var hud_mat = core.loaders.mtl.parseFile(a, init.io, "assets/hud.mtl") catch @panic("failed to load materials file");
    defer hud_mat.deinit();

    const all_objects = [_][]core.loaders.obj.ObjFile{
        core.loaders.obj.readObjDirectory(a, init.io, "assets/meshes") catch @panic("failed to read objects"),
    };

    const user_create_meshes = &[_]core.resources.Manager.Mesh3DCreateInfo{
        .{ .create_mesh = .{
            .info = .{
                .mesh = try core.lib.mesh.Mesh3D.box(a, 10.0, 10.0, 1.0),
                .name = "large_flat_box",
            },
        } },
    };

    defer {
        for (all_objects) |obj_files| {
            for (obj_files) |*obj|
                obj.deinit();
            a.free(obj_files);
        }

        for (user_create_meshes) |m| {
            m.create_mesh.info.mesh.deinit(a);
        }
    }

    const amt_mesh_creates = blk: {
        var total: usize = 0;
        for (all_objects) |files| total += files.len;
        break :blk total + user_create_meshes.len;
    };

    const meshes_objects = a.alloc(
        core.resources.Manager.Mesh3DCreateInfo,
        amt_mesh_creates,
    ) catch @panic("failed to alloc meshes_objects");
    defer a.free(meshes_objects);

    var k: usize = 0;

    for (all_objects) |files| {
        for (files, 0..) |*obj, i| {
            meshes_objects[i + k] = .{
                .create_mesh = .{
                    .obj = obj.*,
                },
            };
        }
        k += files.len;
    }
    for (user_create_meshes) |m| {
        meshes_objects[k] = m;
        k += 1;
    }

    const resources_ci = core.resources.Manager.CreateInfo{
        .materials_files = &[_]core.loaders.mtl.MtlFile{
            global_mat,
            debug_mat,
        },
        .meshes2D = &[_]core.resources.Manager.Mesh2DCreateInfo{},
        .meshes3D = meshes_objects,
    };
    var core_engine = CoreEngine.init(
        a,
        init.io,
        resources_ci,
        shared.systems.Camera.CAMERA_SET_NAME,
        null,
    );

    var consumer_engine = Engine{
        .world = try shared.GameWorld.init(core_engine.allocs.std),
        .systems = shared.SystemManager{},
    };
    defer {
        consumer_engine.world.deinit(core_engine.allocs.std);
        consumer_engine.systems.deinit(core_engine.allocs, core_engine.logical_device.handle, core_engine.alloc_cbs);
        core_engine.deinit();
    }

    try initSystems(core_engine.allocs.std, &consumer_engine, &core_engine);

    core_engine.initImgui();
    consumer_engine.registerSets(&core_engine);
    core_engine.uploadResources();
    consumer_engine.updateSets(&core_engine);
    consumer_engine.initPipelines(&core_engine);

    core_engine.physics.createMeshColliders(
        core_engine.allocs.std,
        &core_engine.resources.meshes3D,
    ) catch @panic("OOM");

    createEntities(&consumer_engine.world, &core_engine.resources, &core_engine.physics);
    consumer_engine.run(&core_engine);
}

fn initSystems(
    a: std.mem.Allocator,
    consumer_engine: *Engine,
    core_engine: *CoreEngine,
) std.mem.Allocator.Error!void {
    const camera = try shared.systems.Camera.init(a, &core_engine.resources, core_engine.renderer.swapchain.extent);
    consumer_engine.systems.addSystem(.Camera, camera);
    try consumer_engine.systems.initSystemEntities(.Camera, &consumer_engine.world, &core_engine.resources);

    const draw_background = try shared.systems.DrawBackground.init(a, &core_engine.resources, core_engine.renderer.swapchain.extent);
    consumer_engine.systems.addSystem(.DrawBackground, draw_background);
    try consumer_engine.systems.initSystemEntities(.DrawBackground, &consumer_engine.world, &core_engine.resources);

    const maze_system_ci = shared.systems.Maze.CreateInfo{
        .main_camera_entity = consumer_engine.systems.plexe.Camera.?.main_camera_entity.?,
        .push_constants = shared.systems.Maze.PushConstants{
            .width = 10,
            .height = 10,
            .pixels_per_cell = 9,
            .cell_size = 2.0,
            .seed = 123456,
            .threshold = 16,
            .maze_origin = .{
                .x = 4.0,
                .y = 0.0,
                .z = 0.0,
            },
        },
        .mesh_options = core.lib.Maze.MeshOptions{
            .cell_size = 2.0,
            .wall_height = 2.0,
            .margin = .{
                .x = 0.5,
                .y = 0.5,
                .z = 0.0,
            },
            .origin = .{
                .x = 4.0,
                .y = 0.0,
                .z = 0.0,
            },
        },
    };

    const maze = try shared.systems.Maze.init(a, &core_engine.resources, maze_system_ci);
    consumer_engine.systems.addSystem(.Maze, maze);
    try consumer_engine.systems.initSystemEntities(.Maze, &consumer_engine.world, &core_engine.resources);

    const debug = shared.systems.Debug{};
    consumer_engine.systems.addSystem(.Debug, debug);
    try consumer_engine.systems.initSystemEntities(.Debug, &consumer_engine.world, &core_engine.resources);
}

fn createEntities(
    world: *shared.GameWorld,
    resources: *const core.resources.Manager,
    physics: *const core.engine.Physics,
) void {
    for ([_]struct { []const u8, []const u8 }{
        .{
            "viking_room.obj",
            "debug.gray",
        },
        .{
            "suzanne.obj",
            "debug.blue",
        },
    }, 0..) |names, i| {
        var ent = world.entities.register(null) catch @panic("OOM");
        ent.addComponent(.mesh3D, core.engine.world.MaterialMesh3D.fromNames(
            resources,
            .{ .mesh = names.@"0", .material = names.@"1" },
        ));

        var tx = core.engine.world.WorldTransform{};
        tx.position = .{
            .x = 0.0,
            .y = @as(f32, @floatFromInt(i)) + @as(f32, @floatFromInt(i)) * 1.5,
            .z = 0.0,
        };
        ent.addComponent(.world_transform, tx);

        var body_def = core.clibs.box3d.DefaultBodyDef();
        body_def.type = core.clibs.box3d.BODY_TYPE_DYNAMIC;
        body_def.position = .{
            .x = 0.0,
            .y = @as(f32, @floatFromInt(i)) + @as(f32, @floatFromInt(i)) * 1.5,
            .z = 0.0,
        };
        body_def.userData = @ptrCast(@constCast(ent.identifier));

        const body_id = core.clibs.box3d.CreateBody(physics.world, &body_def);

        ent.addComponent(.rigid_body, core.engine.world.RigidBody{
            .id = body_id,
        });

        const hull = physics.colliders.get(names.@"0").?;
        var shape_def = core.clibs.box3d.DefaultShapeDef();
        _ = core.clibs.box3d.CreateHullShape(body_id, &shape_def, hull);
    }

    {
        var ent = world.entities.register(null) catch @panic("OOM");

        var tx = core.engine.world.WorldTransform{};
        tx.position = .{
            .x = 2.0,
            .y = 1.5,
            .z = -1.5,
        };
        ent.addComponent(.world_transform, tx);

        var body_def = core.clibs.box3d.DefaultBodyDef();
        body_def.type = core.clibs.box3d.BODY_TYPE_STATIC;
        body_def.position = .{
            .x = 2.0,
            .y = 1.5,
            .z = -1.5,
        };
        body_def.userData = @ptrCast(@constCast(ent.identifier));

        const body_id = core.clibs.box3d.CreateBody(physics.world, &body_def);

        ent.addComponent(.rigid_body, core.engine.world.RigidBody{
            .id = body_id,
        });

        const hull = physics.colliders.get("large_flat_box").?;
        var shape_def = core.clibs.box3d.DefaultShapeDef();
        shape_def.density = 0.0;
        _ = core.clibs.box3d.CreateHullShape(body_id, &shape_def, hull);
    }

    // for (self.meshes2D.ranges.items) |ranges| {
    //     var ent = world.entities.register(null) catch @panic("OOM");
    //     ent.addComponent(.mesh2D, core.engine.world.Mesh2DComponent{
    //         .ranges = ranges,
    //     });
    // }
}
