const std = @import("std");
const log = std.log;
const core = @import("core");
const vki = core.bindings.vulkan_init;
const vma_usage = core.bindings.vma_usage;
const mesh_mod = core.lib.mesh;
const math_mod = core.lib.math;
const c = core.clibs;
const vk = c.vk;
const vma = c.vma;
const checkVk = vki.checkVk;
const sdl = c.sdl;
const VkError = vki.VkError;
const Vec2 = math_mod.Vec2;
const Vec3 = math_mod.Vec3;
const Vec4 = math_mod.Vec4;
const Mat4 = math_mod.Mat4;

pub const std_options = std.Options{
    .log_level = .debug,
};

pub fn main(init: std.process.Init) void {
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
                .mesh = core.lib.mesh.Mesh3D.box(a, 10.0, 10.0, 1.0) catch @panic("OOM"),
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
    }

    var engine = core.engine.Engine.init(
        a,
        init.io,
        core.resources.Manager.CreateInfo{
            .materials_files = &[_]core.loaders.mtl.MtlFile{
                global_mat,
                debug_mat,
            },
            .meshes2D = &[_]core.resources.Manager.Mesh2DCreateInfo{},
            .meshes3D = meshes_objects,
        },
        null,
    );
    defer engine.deinit();

    engine.initRenderer(.{});

    const maze_system_ci = core.engine.systems.Maze.CreateInfo{
        .push_constants = core.engine.systems.Maze.PushConstants{
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

    // engine.initSystems(.{
    const maze = core.engine.systems.Maze.init(a, &engine.resources, maze_system_ci) catch @panic("OOM");
    const debug = core.engine.systems.Debug{};
    const camera = core.engine.systems.Camera.init(a, &engine.resources, engine.swapchain.extent) catch @panic("OOM");
    const draw_background = core.engine.systems.DrawBackground.init(a, &engine.resources, engine.swapchain.extent) catch @panic("OOM");
    // const physics_debug = core.engine.systems.PhysicsDebug.init(a, &engine.resources) catch @panic("OOM");

    engine.system_manager.addSystem(.Maze, maze);
    engine.system_manager.addSystem(.Debug, debug);
    engine.system_manager.addSystem(.Camera, camera);
    engine.system_manager.addSystem(.DrawBackground, draw_background);
    // engine.system_manager.addSystem(.PhysicsDebug, physics_debug);

    // BAD
    // consumer shouldnt facilitate this
    engine.allocateResources();
    engine.initPipelines();

    engine.physics.createMeshes(
        engine.allocs.std,
        &engine.world,
        &engine.resources.meshes3D,
    ) catch @panic("OOM");

    createEntities(&engine.resources, &engine.world, &engine.physics);
    engine.run();
}

fn createEntities(
    resources: *const core.resources.Manager,
    world: *core.engine.world.GameWorld,
    physics: *const core.engine.Physics,
) void {
    for (0..3) |i| {
        var ent = world.entities.register(null) catch @panic("OOM");
        ent.addComponent(.mesh3D, core.engine.world.MaterialMesh3D.fromNames(
            resources,
            .{
                .mesh = "viking_room.obj",
                .material = "globals.viking_room",
            },
        ));

        var tx = core.engine.world.WorldTransform{};
        tx.matrix = tx.matrix.translate(.{
            .x = 0.0,
            .y = @as(f32, @floatFromInt(i)) + @as(f32, @floatFromInt(i)) * 1.5,
            .z = 0.0,
        });
        ent.addComponent(.world_transform, tx);

        var body_def = core.clibs.box3d.DefaultBodyDef();
        body_def.type = core.clibs.box3d.BODY_TYPE_DYNAMIC;
        body_def.position = .{
            .x = 0.0,
            .y = @as(f32, @floatFromInt(i)) + @as(f32, @floatFromInt(i)) * 1.5,
            .z = 60.0,
        };
        body_def.userData = @ptrCast(@constCast(ent.identifier));

        const body_id = core.clibs.box3d.CreateBody(physics.world, &body_def);

        ent.addComponent(.rigid_body, core.engine.world.RigidBody{
            .id = body_id,
        });

        var shape_def = core.clibs.box3d.DefaultShapeDef();
        shape_def.density = 1.0;

        const box = core.clibs.box3d.MakeBoxHull(
            0.5,
            0.5,
            0.5,
        );

        _ = core.clibs.box3d.CreateHullShape(
            body_id,
            &shape_def,
            &box.base,
        );
    }
    var ent = world.entities.register(null) catch @panic("OOM");
    ent.addComponent(.mesh3D, core.engine.world.MaterialMesh3D.fromNames(
        resources,
        .{
            .mesh = "large_flat_box",
            .material = "debug.gray",
        },
    ));

    var tx = core.engine.world.WorldTransform{};
    tx.matrix = tx.matrix.translate(.{
        .x = 2.0,
        .y = 1.5,
        .z = 0.5,
    });
    ent.addComponent(.world_transform, tx);

    // const mesh = core.bindings.box3d_usage.meshes3DMesh(
    //     resources.meshes3D,
    //     resources.meshes3D.mesh_indices.get("large_flat_box").?,
    // );
    var body_def = core.clibs.box3d.DefaultBodyDef();
    body_def.type = core.clibs.box3d.BODY_TYPE_STATIC;
    body_def.position = .{
        .x = 2.0,
        .y = 1.5,
        .z = 0.5,
    };
    body_def.userData = @ptrCast(@constCast(ent.identifier));

    const body_id = core.clibs.box3d.CreateBody(physics.world, &body_def);

    ent.addComponent(.rigid_body, core.engine.world.RigidBody{
        .id = body_id,
    });

    var shape_def = core.clibs.box3d.DefaultShapeDef();
    const box = core.clibs.box3d.MakeBoxHull(
        5.0,
        5.0,
        0.5,
    );
    _ = core.clibs.box3d.CreateHullShape(
        body_id,
        &shape_def,
        &box.base,
    );

    // const mesh = physics.meshes.get("large_flat_box").?;
    // const scale = core.bindings.box3d_usage.fromCoreVec3(core.lib.math.Vec3.ONE);
    // var shape_def = core.clibs.box3d.DefaultShapeDef();
    // shape_def.density = 0.0;
    // _ = core.clibs.box3d.CreateMeshShape(body_id, &shape_def, mesh, scale);

    // for (self.meshes2D.ranges.items) |ranges| {
    //     var ent = world.entities.register(null) catch @panic("OOM");
    //     ent.addComponent(.mesh2D, core.engine.world.Mesh2DComponent{
    //         .ranges = ranges,
    //     });
    // }
}
