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
        amt_meshes_objects,
    ) catch @panic("failed to alloc meshes_objects");
    defer a.free(meshes_objects);

    var k: usize = 0;
    for (all_objects) |files| {
        for (files, 0..) |*obj, i| {
            meshes_objects[i + k] = .{
                .obj = obj.*,
            };
        }
        k += files.len;
    }

    // BAD
    // this should be internal?
    const hud_quad = core.mesh.Mesh2D.quad(a, 0.6, -1.0, 0.4, 0.4) catch @panic("failed to create hud quad");
    defer hud_quad.deinit(a);

    var engine = core.VulkanEngine.init(
        a,
        .{
            .camera = camera,
            .materials_files = &[_]core.mtl_loader.MtlFile{ global_mat, debug_mat },
            .mesh_objs = meshes_objects,
        },
        .{
            .materials_file = hud_mat,
            .mesh_objs = &[_]core.HudPipeline.AllocatedData.CreateData.MeshCreateInfo{.{
                .mesh = hud_quad,
                .material_index = 0,
            }},
        },
        null,
    );

    defer engine.deinit();

    engine.run();
}
