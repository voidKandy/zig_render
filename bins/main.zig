const std = @import("std");
const log = std.log;
const core = @import("core");
const vki = core.vulkan_init;
const vma_usage = core.vma_usage;
const mesh_mod = core.mesh;
const math_mod = core.math;
const c = core.clibs;
const vk = c.vk;
const vma = c.vma;
const checkVk = vki.checkVk;
const sdl = c.sdl;
const VkError = core.vulkan_init.VkError;
const Vec2 = core.math.Vec2;
const Vec3 = core.math.Vec3;
const Vec4 = core.math.Vec4;
const Mat4 = core.math.Mat4;

pub const std_options = std.Options{
    .log_level = .debug,
};

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        @panic("Leaked memory");
    };
    const a = gpa.allocator();
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
    var cwd_buff: [1024]u8 = undefined;
    const cwd = std.process.getCwd(cwd_buff[0..]) catch @panic("cwd_buff too small");
    std.log.info("Running from: {s}", .{cwd});

    const camera = core.Camera{};
    var global_mat = core.mtl_loader.parseFile(a, "assets/globals.mtl") catch @panic("failed to load materials file");
    defer global_mat.deinit();
    var debug_mat = core.mtl_loader.parseFile(a, "assets/debug.mtl") catch @panic("failed to load materials file");
    defer debug_mat.deinit();

    var hud_mat = core.mtl_loader.parseFile(a, "assets/hud.mtl") catch @panic("failed to load materials file");
    defer hud_mat.deinit();

    const all_objects =
        [_][]core.obj_loader.ObjFile{
            core.obj_loader.readObjDirectory(a, "assets/meshes") catch @panic("failed to read objects"),
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
        core.MeshPipeline.AllocatedData.CreateData.MeshCreateInfo,
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

    var engine = core.VulkanEngine.init(
        a,
        null,
    );
    defer engine.deinit();

    // var maze = core.Maze.initHallwaySquare(
    //     a,
    //     10,
    // ) catch @panic("failed to create maze");
    var maze = core.Maze.init(a, 10, 10) catch @panic("OOM");
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
    const maze_quad = core.mesh.Mesh2D.ndcQuad(a, quad_size, quad_size) catch @panic("failed to create hud quad");
    defer maze_quad.deinit(a);

    // top-right placement in -1..1 UI space
    const maze_quad_coords = core.math.Vec2.make(
        1.0 - (quad_size / 2.0) - margin,
        margin,
    );

    const maze_mesh3D = core.mesh.Mesh3D.fromMaze(a, maze, 2.0, 2.0) catch @panic("failed to create 3D maze mesh");
    defer maze_mesh3D.deinit(a);

    meshes_objects[amt_meshes_objects] = .{
        .create_mesh = .{
            .info = .{
                .mesh = maze_mesh3D,
                .material_idx = 0,
            },
        },
    };
    const mesh_pipeline_create_data: core.MeshPipeline.AllocatedData.CreateData =
        .{
            .camera = camera,
            .materials_files = &[_]core.mtl_loader.MtlFile{ global_mat, debug_mat },
            .create_meshes = meshes_objects,
        };

    const hud_pipeline_create_data: core.HudPipelines.AllocatedData.CreateData =
        .{
            .meshes = &[_]core.HudPipelines.AllocatedData.CreateData.HudMesh{
                .{
                    .maze = .{
                        .mesh = maze_quad,
                        .screen_coordinates = maze_quad_coords,
                    },
                },
            },
            .maze = maze,
            .pixels_per_cell = pixels_per_cell,
        };
    engine.initData(
        mesh_pipeline_create_data,
        hud_pipeline_create_data,
    );

    engine.run();
}
