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
    // var cwd_buff: [1024]u8 = undefined;
    // const cwd = std.process.getCwd(cwd_buff[0..]) catch @panic("cwd_buff too small");
    // const cwd = std.Io.Dir.cwd();
    // std.log.info("Running from: {s}", .{cwd});

    var global_mat = core.loaders.mtl.parseFile(a, init.io, "assets/globals.mtl") catch @panic("failed to load materials file");
    defer global_mat.deinit();
    var debug_mat = core.loaders.mtl.parseFile(a, init.io, "assets/debug.mtl") catch @panic("failed to load materials file");
    defer debug_mat.deinit();

    var hud_mat = core.loaders.mtl.parseFile(a, init.io, "assets/hud.mtl") catch @panic("failed to load materials file");
    defer hud_mat.deinit();

    const all_objects =
        [_][]core.loaders.obj.ObjFile{
            core.loaders.obj.readObjDirectory(a, init.io, "assets/meshes") catch @panic("failed to read objects"),
            // core.obj_loader.readObjDirectory(a, "assets/widgets") catch @panic("failed to read objects"),
            // core.obj_loader.readObjDirectory(a, "assets/primitives") catch @panic("failed to read objects"),
        };

    defer {
        for (all_objects) |obj_files| {
            for (obj_files) |*obj|
                obj.deinit();
            a.free(obj_files);
        }
    }

    const amt_meshes_objects = blk: {
        var total: usize = 0;
        for (all_objects) |files| total += files.len;
        break :blk total;
    };

    const meshes_objects = a.alloc(
        core.pipelines.MeshPipeline.AllocatedData.CreateData.MeshCreateInfo,
        // BAD
        amt_meshes_objects + 1,
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

    var engine = core.engine.Engine.init(
        a,
        init.io,
        null,
    );
    defer engine.deinit();

    // var maze = core.Maze.initHallwaySquare(
    //     a,
    //     10,
    // ) catch @panic("failed to create maze");
    var maze = core.lib.Maze.init(a, 10, 10) catch @panic("OOM");
    defer maze.deinit(a);
    maze.generate(a, 16, 12345);

    const pixels_per_cell = 9;
    // const window_aspect = @as(f32, @floatFromInt(engine.swapchain.extent.width)) / @as(f32, @floatFromInt(engine.swapchain.extent.height));
    // const maze_aspect = @as(f32, @floatFromInt(maze.width)) / @as(f32, @floatFromInt(maze.height));

    // portion of window height to use for the maze quad
    // const quad_h: f32 = 0.7;
    // const quad_w: f32 = quad_h * maze_aspect / window_aspect;
    const margin: f32 = 0.05;
    const quad_size = 0.2;
    const maze_quad = mesh_mod.Mesh2D.ndcQuad(a, quad_size, quad_size) catch @panic("failed to create hud quad");
    defer maze_quad.deinit(a);

    // top-right placement in -1..1 UI space
    const maze_quad_coords = Vec2.make(
        1.0 - (quad_size / 2.0) - margin,
        margin,
    );

    const maze_mesh_options = core.lib.Maze.MeshOptions{
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
    };

    const maze_mesh3D = maze_mesh_options.createMesh(a, maze) catch @panic("failed to create 3D maze mesh");

    defer maze_mesh3D.deinit(a);

    meshes_objects[amt_meshes_objects] = .{
        .create_mesh = .{
            .info = .{
                .mesh = maze_mesh3D,
                .material_idx = 0,
            },
        },
    };
    const mesh_pipeline_create_data: core.pipelines.MeshPipeline.AllocatedData.CreateData =
        .{
            .materials_files = &[_]core.loaders.mtl.MtlFile{ global_mat, debug_mat },
            .create_meshes = meshes_objects,
        };

    const hud_pipeline_create_data: core.pipelines.HudPipelines.AllocatedData.CreateData =
        .{
            .meshes = &[_]core.pipelines.HudPipelines.AllocatedData.CreateData.HudMesh{
                .{
                    .maze = .{
                        .mesh = maze_quad,
                        .screen_coordinates = maze_quad_coords,
                    },
                },
            },
            .maze = maze,
            .pixels_per_cell = pixels_per_cell,
            .cell_size = maze_mesh_options.cell_size,
            .maze_origin = maze_mesh_options.origin,
        };

    engine.initPipelines(
        mesh_pipeline_create_data,
        hud_pipeline_create_data,
    );

    engine.run();
}
