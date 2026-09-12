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
        core.resources.Manager.Mesh3DCreateInfo,
        amt_meshes_objects,
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
    engine.initSystems(maze_system_ci);

    engine.allocateResources();

    engine.initPipelines();

    engine.run();
}
