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

    var materials_file = core.mtl_loader.parseFile(gpa.allocator(), "assets/globals.mtl") catch @panic("failed to load materials file");
    defer materials_file.deinit();

    var engine = core.VulkanEngine.init(
        gpa.allocator(),
        .{
            .camera = core.Camera{},
            .materials_file = materials_file,
            .meshes_path = "assets/meshes",
            .terrain_heightmap_file_name = "assets/terrain_tst.png",
            .terrain_material_name = "statue",
        },
        null,
    );

    defer engine.deinit();

    engine.run();
}
