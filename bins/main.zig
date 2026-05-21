const std = @import("std");
const log = std.log;
const core = @import("core");
const vki = core.vulkan_init;
const texs = core.textures;
const vma_usage = core.vma_usage;
const BoundDescriptor = core.BoundDescriptor;
const ResourceManager = core.ResourceManager;
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

    const objects = &[_]core.GraphicsPipeline.AllocatedData.MeshObject{
        .{
            .object = core.obj_loader.parseFile(gpa.allocator(), "assets/viking_room.obj") catch @panic("failed to read viking_room.obj"),
        },
        .{
            .object = core.obj_loader.parseFile(gpa.allocator(), "assets/monkey.obj") catch @panic("failed to read monkey.obj"),
            .transform = blk: {
                const translate = core.math.Mat4.IDENTITY.translate(core.math.Vec3.make(0, 2, 0));
                const rotate = core.math.Mat4.IDENTITY.rotate(core.math.Vec3.make(0, 1, 0), std.math.pi / 2.0).rotate(core.math.Vec3.make(1, 0, 0), std.math.pi / 2.0);
                break :blk translate.mul(rotate);
            },
        },
    };
    defer for (objects) |*o| @constCast(&o.object).deinit();

    var engine = core.VulkanEngine.init(
        gpa.allocator(),
        null,

        .{
            .camera = core.Camera{},
            .materials_file = materials_file,
            .mesh_objects = objects,
        },
    );

    defer engine.deinit();

    engine.run();
}
