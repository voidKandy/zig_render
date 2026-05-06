const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.ResourceManager);
const core = @import("root.zig");

/// Instead of writing the methods for managing materials in ResourceManager,
/// I decided to use this struct directly. Mostly for clear separation of concerns,
/// which follows from the decision to write a this instead of adding a
/// material-specific field to ResourceManager
const Self = @This();

const MaterialUploaded = struct { image_id: u32, sampler_id: u32 };
pub const Mesh = struct { mesh: core.mesh.Mesh3D, material_name: []const u8 };

/// material file data, keyed by material name
file_data: std.StringHashMapUnmanaged([*c]u8) = .{},

const Error = std.fmt.BufPrintError || error{FailedToLoadImage};
const ASSETS_PATH = "assets/";

pub fn deinit(self: *@This()) void {
    var iter =
        self.file_data.valueIterator();
    while (iter.next()) |dat| {
        core.clibs.stbi.image_free(dat);
    }
}

// pub fn initFromMaterialFile(
//     self: *@This(),
//     a: core.VulkanEngine.Allocators,
//     resource_manager: core.ResourceManager,
//     mtl: core.mtl_loader.MtlFile,
// ) anyerror!@This() {

// for (mtl.materials) |mat| {
//     // const path = try std.fmt.allocPrint(a.std, ASSETS_PATH ++ "{s}", .{mat.map_Kd});
//     // defer a.std.free(path);

//     var width: c_int = undefined;
//     var height: c_int = undefined;
//     var channels: c_int = undefined;

//     // This is just to make the API more zig friendly. Convert to C 0-term string
//     // on the stack.
//     var buffer: [512]u8 = undefined;
//     const filepathz = try std.fmt.bufPrintZ(buffer[0..], ASSETS_PATH ++ "{s}", .{mat.map_Kd});

//     log.info("Attempting to load image from: {s}", .{filepathz});

//     const image_data = core.clibs.stbi.load(
//         filepathz.ptr,
//         &width,
//         &height,
//         &channels,
//         core.clibs.stbi.rgb_alpha,
//     );
//     if (image_data == null) {
//         return error.FailedToLoadImage;
//     }
//     defer core.clibs.stbi.image_free(image_data);

//     var img = core.textures.loadImageFromFile(
//         a.vma,
//         &engine.upload_context,
//         engine.logical_device,
//         path,
//     ) catch @panic("Failed to load image");

//     const image_view_ci = vk.ImageViewCreateInfo{
//         .sType = vk.STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
//         .viewType = vk.IMAGE_VIEW_TYPE_2D,
//         .image = img.image,
//         .format = vk.FORMAT_R8G8B8A8_SRGB,
//         .components = .{
//             .r = vk.COMPONENT_SWIZZLE_IDENTITY,
//             .g = vk.COMPONENT_SWIZZLE_IDENTITY,
//             .b = vk.COMPONENT_SWIZZLE_IDENTITY,
//             .a = vk.COMPONENT_SWIZZLE_IDENTITY,
//         },
//         .subresourceRange = .{
//             .aspectMask = vk.IMAGE_ASPECT_COLOR_BIT,
//             .baseMipLevel = 0,
//             .levelCount = 1,
//             .baseArrayLayer = 0,
//             .layerCount = 1,
//         },
//     };
//     checkVk(vk.CreateImageView(
//         engine.logical_device.handle,
//         &image_view_ci,
//         engine.alloc_cbs,
//         &img.view,
//     )) catch @panic("Failed to create image view");

//     const id = resources.insert(.{ .image = img }) catch @panic("OOM");
//     _ = id;
// use name to keep track of id
// some_map.put(mat.name, id) catch @panic("OOM");
// }
// }
