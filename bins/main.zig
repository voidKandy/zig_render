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
    const meshes_object_files = core.obj_loader.readObjDirectory(a, "assets/meshes") catch @panic("failed to read objects");
    const widgets_object_files = core.obj_loader.readObjDirectory(a, "assets/widgets") catch @panic("failed to read objects");
    defer {
        for (meshes_object_files) |*obj|
            obj.deinit();
        a.free(meshes_object_files);
        for (widgets_object_files) |*obj|
            obj.deinit();
        a.free(widgets_object_files);
    }
    const amt_meshes_objects = meshes_object_files.len + widgets_object_files.len;

    const meshes_objects = a.alloc(
        core.GraphicsPipeline.AllocatedData.CreateData.MeshCreateInfo,
        amt_meshes_objects,
    ) catch @panic("failed to alloc meshes_objects");
    defer a.free(meshes_objects);
    for (meshes_object_files, 0..) |*obj, i| meshes_objects[i] = .{
        .obj = obj.*,
    };
    for (widgets_object_files, 0..) |*obj, i| meshes_objects[i + meshes_object_files.len] = .{
        .obj = obj.*,
    };

    var engine = core.VulkanEngine.init(
        a,
        .{
            .camera = camera,
            .materials_files = &[_]core.mtl_loader.MtlFile{ global_mat, debug_mat },
            .mesh_objs = meshes_objects,
        },
        null,
    );

    defer engine.deinit();

    engine.run();
}
