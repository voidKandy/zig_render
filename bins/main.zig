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

    engine.physics = .init(.{}, engine.alloc_cbs);

    // BAD
    // dont like consumer calling this
    createEntities(engine.resources, &engine.world, engine.physics.world);
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
        .pd = .{
            .camera_descriptor_set_layout_name = core.engine.systems.Camera.CAMERA_SET_NAME,
            .device = engine.logical_device.handle,
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

    engine.initSystems(.{
        .Maze = core.engine.systems.Maze.init(a, &engine.world, &engine.resources, maze_system_ci) catch @panic("OOM"),
        .Debug = .{},
        .Camera = core.engine.systems.Camera.init(a, &engine.resources, &engine.world, .{}, engine.swapchain.extent) catch @panic("OOM"),
        .DrawBackground = core.engine.systems.DrawBackground.init(a, &engine.resources, engine.swapchain.extent) catch @panic("OOM"),
        .RenderSystem = core.engine.graphics_pipelines.Mesh3DPipeline.RenderSystem.init(a, &engine.world, &engine.resources) catch @panic("OOM"),
        // .PhysicsDebug = core.engine.systems.PhysicsDebug{},
    });
    engine.allocateResources();
    engine.initPipelines();

    engine.run();
}

fn createEntities(
    resources: core.resources.Manager,
    world: *core.engine.world.GameWorld,
    physics_world: core.clibs.box3D.WorldId,
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

        var tx = core.engine.world.Transform{};
        tx.matrix = tx.matrix.translate(.{
            .x = 0.0,
            .y = @as(f32, @floatFromInt(i)) + @as(f32, @floatFromInt(i)) * 1.5,
            .z = 1.0,
        });
        ent.addComponent(.transform, tx);

        var body_def = core.clibs.box3D.DefaultBodyDef();
        body_def.type = core.clibs.box3D.BODY_TYPE_DYNAMIC;
        body_def.position = .{
            .x = 0.0,
            .y = @as(f32, @floatFromInt(i)) + @as(f32, @floatFromInt(i)) * 1.5,
            .z = 1.0,
        };

        const body_id = core.clibs.box3D.CreateBody(physics_world, &body_def);

        ent.addComponent(.rigid_body, core.engine.world.RigidBody{
            .id = body_id,
        });

        var shape_def = core.clibs.box3D.DefaultShapeDef();
        shape_def.density = 1.0;

        const box = core.clibs.box3D.MakeBoxHull(
            0.5,
            0.5,
            0.5,
        );

        _ = core.clibs.box3D.CreateHullShape(
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

    var tx = core.engine.world.Transform{};
    tx.matrix = tx.matrix.translate(.{
        .x = 2.0,
        .y = 1.5,
        .z = 0.5,
    });
    ent.addComponent(.transform, tx);

    var body_def = core.clibs.box3D.DefaultBodyDef();
    body_def.type = core.clibs.box3D.BODY_TYPE_STATIC;
    body_def.position = .{
        .x = 2.0,
        .y = 1.5,
        .z = 0.5,
    };

    const body_id = core.clibs.box3D.CreateBody(physics_world, &body_def);

    ent.addComponent(.rigid_body, core.engine.world.RigidBody{
        .id = body_id,
    });

    var shape_def = core.clibs.box3D.DefaultShapeDef();
    shape_def.density = 0.0;

    const box = core.clibs.box3D.MakeBoxHull(
        10.0,
        10.0,
        1.0,
    );

    _ = core.clibs.box3D.CreateHullShape(
        body_id,
        &shape_def,
        &box.base,
    );

    // for (self.meshes2D.ranges.items) |ranges| {
    //     var ent = world.entities.register(null) catch @panic("OOM");
    //     ent.addComponent(.mesh2D, core.engine.world.Mesh2DComponent{
    //         .ranges = ranges,
    //     });
    // }
}
