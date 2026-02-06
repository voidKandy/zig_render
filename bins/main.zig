const std = @import("std");
const log = std.log;
const core = @import("core");
const vki = core.vulkan_init;
const texs = core.textures;
const vma_usage = core.vma_usage;
const PipelineObject = core.PipelineObject;
const PipelineObjManager = core.PipelineObjManager;
const ResourceManager = core.ResourceManager;
const pipelines = @import("pipelines");
const mesh_mod = core.mesh;
const c = core.clibs;
const vk = c.vk;
const checkVk = vki.checkVk;
const sdl = c.sdl;
const VkError = core.vulkan_init.VkError;
const Vec2 = core.math.Vec2;
const Vec3 = core.math.Vec3;
const Vec4 = core.math.Vec4;
const Mat4 = core.math.Mat4;

const vk_alloc_cbs: ?*vk.AllocationCallbacks = null;

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

    var engine = core.VulkanEngine.init(gpa.allocator(), &initResources, &initPipelineObjects);
    defer engine.deinit();

    engine.run();
}

fn initResources(engine: *core.VulkanEngine) anyerror!void {
    engine.resources = core.ResourceManager.init(engine.allocator) catch @panic("OOM");
    initMeshes(engine);
    initBackgroundDrawImage(engine);
    initTextureImage(engine);
    initTextureSampler(engine);
}

fn initPipelineObjects(engine: *core.VulkanEngine) anyerror!void {
    engine.pipeline_objects = PipelineObjManager.init(engine.allocator);

    const init_data = PipelineObject.InitData{
        .main_render_pass = engine.main_render_pass,
        .swapchain_extent = engine.swapchain.extent,
        .global_descriptor_set_layout = engine.frames.global_descriptor_set_layout,
        .resources = engine.resources,
    };
    const allocs = PipelineObject.Allocators{
        .std = engine.allocator,
        .vma = engine.vma_allocator,
        .descriptor = &engine.global_descriptor_allocator,
    };

    inline for ([_]struct { []const u8, usize, type }{
        .{ "triangle", 0, pipelines.Triangle },
        .{ "scene3D", 1, pipelines.Scene3D },
    }) |v| {
        var entry = PipelineObject.create(v.@"2", engine.allocator) catch @panic("OOM");
        // BAD
        // This should be done in some other way
        // eventually meshes should be initialized with some string key to keep track of ids
        const resources = &[_]ResourceManager.ResourceID{engine.resources.getId(.mesh3D, v.@"1").?};
        entry.init(
            allocs,
            init_data,
            resources,
            engine.logical_device,
            vk_alloc_cbs,
        );
        engine.pipeline_objects.insert(allocs.std, .graphics, "meshes", v.@"0", entry) catch @panic("OOM");
    }

    {
        const background_image = engine.resources.getId(.image, 0).?;
        var entry = PipelineObject.create(pipelines.BackgroundEffects, engine.allocator) catch @panic("OOM");
        entry.init(
            allocs,
            init_data,
            &[_]ResourceManager.ResourceID{background_image},
            engine.logical_device,
            vk_alloc_cbs,
        );
        engine.pipeline_objects.insert(allocs.std, .compute, "background_image", null, entry) catch @panic("OOM");
    }
}

fn initMeshes(engine: *core.VulkanEngine) void {
    const vertices_indices = [_]struct { []const mesh_mod.Vertex3D, []const u16 }{
        .{
            // this is a triangle
            &[_]mesh_mod.Vertex3D{
                .{
                    .position = Vec3.make(-1.0, 1.0, 0.0),
                    .normal = Vec3.ZERO,
                    .color = Vec3.make(1.0, 0.0, 0.0),
                    .uv = Vec2.make(1.0, 0.0),
                },
                .{
                    .position = Vec3.make(1.0, 1.0, 0.0),
                    .normal = Vec3.ZERO,
                    .color = Vec3.make(0.0, 0.0, 1.0),
                    .uv = Vec2.make(0.0, 1.0),
                },
                .{
                    .position = Vec3.make(0.0, -1.0, 0.0),
                    .normal = Vec3.ZERO,
                    .color = Vec3.make(1.0, 1.0, 1.0),
                    .uv = Vec2.make(1.0, 1.0),
                },
            },
            &[_]u16{ 0, 1, 2 },
        },
        .{
            &[_]mesh_mod.Vertex3D{
                .{
                    .position = Vec3.make(-0.5, -0.5, 0.0),
                    .normal = Vec3.ZERO,
                    .color = Vec3.make(1.0, 0.0, 0.0),
                    .uv = Vec2.make(1.0, 0.0),
                },
                .{
                    .position = Vec3.make(0.5, -0.5, 0.0),
                    .normal = Vec3.ZERO,
                    .color = Vec3.make(0.0, 1.0, 0.0),
                    .uv = Vec2.make(0.0, 0.0),
                },
                .{
                    .position = Vec3.make(0.5, 0.5, 0.0),
                    .normal = Vec3.ZERO,
                    .color = Vec3.make(0.0, 0.0, 1.0),
                    .uv = Vec2.make(0.0, 1.0),
                },
                .{
                    .position = Vec3.make(-0.5, 0.5, 0.0),
                    .normal = Vec3.ZERO,
                    .color = Vec3.make(1.0, 1.0, 1.0),
                    .uv = Vec2.make(1.0, 1.0),
                },
            },
            &[_]u16{ 0, 1, 2, 2, 3, 0 },
        },
        .{
            &[_]mesh_mod.Vertex3D{
                .{
                    .position = Vec3.make(-0.5, -0.5, -0.5),
                    .normal = Vec3.ZERO,
                    .color = Vec3.make(1.0, 0.0, 0.0),
                    .uv = Vec2.make(0.0, 0.0),
                },
                .{
                    .position = Vec3.make(0.5, -0.5, -0.5),
                    .normal = Vec3.ZERO,
                    .color = Vec3.make(0.0, 1.0, 0.0),
                    .uv = Vec2.make(1.0, 0.0),
                },
                .{
                    .position = Vec3.make(0.5, 0.5, -0.5),
                    .normal = Vec3.ZERO,
                    .color = Vec3.make(0.0, 0.0, 1.0),
                    .uv = Vec2.make(1.0, 1.0),
                },
                .{
                    .position = Vec3.make(-0.5, 0.5, -0.5),
                    .normal = Vec3.ZERO,
                    .color = Vec3.make(1.0, 1.0, 1.0),
                    .uv = Vec2.make(0.0, 1.0),
                },
            },
            &[_]u16{ 0, 1, 2, 2, 3, 0 },
        },
    };

    for (vertices_indices) |vi| {
        var mesh = mesh_mod.Mesh3D.init(engine.allocator, vi.@"0", vi.@"1") catch @panic("OOM");
        mesh.upload(engine.vma_allocator, &engine.upload_context, engine.logical_device);
        _ = engine.resources.insert(.{ .mesh3D = mesh }) catch @panic("OOM");
    }
}

fn initBackgroundDrawImage(engine: *core.VulkanEngine) void {
    var image: vma_usage.AllocatedImage = undefined;
    image.format = core.VulkanEngine.MAIN_RENDER_PASS_IMAGE_FORMAT;
    image.extent = vk.Extent3D{
        .width = engine.swapchain.extent.width,
        .height = engine.swapchain.extent.height,
        .depth = 1,
    };

    const usages: vk.ImageUsageFlags =
        vk.IMAGE_USAGE_TRANSFER_SRC_BIT |
        vk.IMAGE_USAGE_TRANSFER_DST_BIT |
        vk.IMAGE_USAGE_STORAGE_BIT | vk.IMAGE_USAGE_COLOR_ATTACHMENT_BIT;

    const ci = vki.imageCreateInfo(image.format, usages, image.extent);

    const ai = c.vma.AllocationCreateInfo{
        .usage = c.vma.MEMORY_USAGE_GPU_ONLY,
        .requiredFlags = vk.MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
    };

    checkVk(c.vma.CreateImage(engine.vma_allocator, &ci, &ai, &image.image, &image.allocation, null)) catch
        @panic("failed to create draw image");

    //build a image-view for the draw image to use for rendering
    const render_view_info = vki.imageViewCreateInfo(image.format, image.image, vk.IMAGE_ASPECT_COLOR_BIT);

    checkVk(vk.CreateImageView(engine.logical_device.handle, &render_view_info, vk_alloc_cbs, &image.view)) catch @panic("failed to create image view");

    _ = engine.resources.insert(.{ .image = image }) catch @panic("OOM");
}

/// Currently unused
fn initTextureImage(engine: *core.VulkanEngine) void {
    const test_img = texs.loadImageFromFile(engine.vma_allocator, &engine.upload_context, engine.logical_device, "assets/test_img.jpg") catch @panic("Failed to load image");

    const image_view_ci = vk.ImageViewCreateInfo{
        .sType = vk.STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .viewType = vk.IMAGE_VIEW_TYPE_2D,
        .image = test_img.image,
        .format = vk.FORMAT_R8G8B8A8_SRGB,
        .components = .{
            .r = vk.COMPONENT_SWIZZLE_IDENTITY,
            .g = vk.COMPONENT_SWIZZLE_IDENTITY,
            .b = vk.COMPONENT_SWIZZLE_IDENTITY,
            .a = vk.COMPONENT_SWIZZLE_IDENTITY,
        },
        .subresourceRange = .{
            .aspectMask = vk.IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1,
        },
    };

    var lost_empire = texs.Texture{
        .image = .{
            .allocation = test_img.allocation,
            .image = test_img.image,
        },
        .image_view = null,
    };

    checkVk(vk.CreateImageView(engine.logical_device.handle, &image_view_ci, vk_alloc_cbs, &lost_empire.image_view)) catch @panic("Failed to create image view");

    _ = engine.resources.insert(.{ .texture = lost_empire }) catch @panic("OOM");
}

fn initTextureSampler(engine: *core.VulkanEngine) void {
    var sampler: vk.Sampler = undefined;
    const ci = vk.SamplerCreateInfo{
        .sType = vk.STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = vk.FILTER_LINEAR,
        .minFilter = vk.FILTER_LINEAR,
        .addressModeU = vk.SAMPLER_ADDRESS_MODE_REPEAT,
        .addressModeV = vk.SAMPLER_ADDRESS_MODE_REPEAT,
        .addressModeW = vk.SAMPLER_ADDRESS_MODE_REPEAT,
        .anisotropyEnable = vk.TRUE,
        .maxAnisotropy = engine.physical_device.properties.limits.maxSamplerAnisotropy,
        .borderColor = vk.BORDER_COLOR_INT_OPAQUE_BLACK,
        .unnormalizedCoordinates = vk.FALSE,
        .compareEnable = vk.FALSE,
        .compareOp = vk.COMPARE_OP_ALWAYS,
        .mipmapMode = vk.SAMPLER_MIPMAP_MODE_LINEAR,
        .mipLodBias = 0.0,
        .minLod = 0.0,
        .maxLod = 0.0,
    };

    checkVk(vk.CreateSampler(engine.logical_device.handle, &ci, null, &sampler)) catch @panic("failed to create sampler");

    _ = engine.resources.insert(.{ .sampler = sampler }) catch @panic("OOM");
}
