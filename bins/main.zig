const std = @import("std");
const log = std.log;
const core = @import("core");
const vki = core.vulkan_init;
const texs = core.textures;
const vma_usage = core.vma_usage;
const PipelineObject = core.PipelineObject;
const PipelineObjManager = core.PipelineObjManager;
const BoundDescriptor = core.BoundDescriptor;
const ResourceManager = core.ResourceManager;
const tools = @import("tools");
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

    var engine = core.VulkanEngine.init(
        gpa.allocator(),
        null,
        &initDescriptors,
        &initResources,
    );
    defer engine.deinit();

    engine.run();
}

fn initDescriptors(engine: *core.VulkanEngine) std.mem.Allocator.Error!std.StringHashMap(BoundDescriptor) {
    var map = std.StringHashMap(BoundDescriptor).init(engine.allocs.std);
    var writer = try core.descriptor.Writer.init(engine.allocs.std);
    defer writer.deinit(engine.allocs.std);
    var builder = core.descriptor.LayoutBuilder.init(engine.allocs.std);
    defer builder.deinit(engine.allocs.std);

    const camera = tools.Camera{};

    // this is migth be an unneccsarry abstraction
    const bound_camera = core.BoundDescriptor.init(
        tools.Camera.GPUData,
        tools.Camera,
        &engine.allocs,
        vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        vk.SHADER_STAGE_VERTEX_BIT,
        vk.BUFFER_USAGE_UNIFORM_BUFFER_BIT,
        c.vma.MEMORY_USAGE_CPU_TO_GPU,
        camera,
        &tools.Camera.control,
    );

    builder.addBinding(engine.allocs.std, 0, bound_camera.descriptor_type, bound_camera.descriptor_stage);
    builder.addBinding(engine.allocs.std, 1, vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, vk.SHADER_STAGE_FRAGMENT_BIT);

    engine.descriptor_set_layout = builder.build(engine.logical_device.handle, null, 0, engine.alloc_cbs);
    engine.descriptor_set = engine.allocs.global_descriptor.allocate(engine.logical_device.handle, engine.descriptor_set_layout, null);

    writer.writeBuffer(engine.allocs.std, 0, bound_camera.data.buffer, @sizeOf(tools.Camera.GPUData), 0, bound_camera.descriptor_type);

    try map.put("camera_data", bound_camera);

    // BAD!!
    // This exture and sampler leaks to Scene3D AND Camera
    // maybe textures should be bundled with samplers in a one - to - many relationship
    // that way this could be done programaitically
    // For now, this is fine
    const image_id = engine.resources.getId(.image, 1).?;
    const sampler_id = engine.resources.getId(.sampler, 0).?;
    writer.writeImage(
        engine.allocs.std,
        1,
        engine.resources.query(image_id).?.image.view,
        engine.resources.query(sampler_id).?.sampler,
        vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
    );

    writer.updateSet(
        engine.logical_device.handle,
        engine.descriptor_set,
    );

    return map;
}

fn initResources(engine: *core.VulkanEngine) anyerror!ResourceManager {
    var resources = core.ResourceManager.init(engine.allocs.std) catch @panic("OOM");

    var global_mtl = try core.mtl_loader.parseFile(engine.allocs.std, "assets/globals.mtl");
    defer global_mtl.deinit();

    _ = resources.insert(initBackgroundDrawImage(engine.allocs, engine.swapchain, engine.logical_device.handle, engine.alloc_cbs)) catch @panic("Failed to initialize background draw image");
    const image_id = resources.insert(initTextureImage(engine.allocs, &engine.upload_context, engine.logical_device, engine.alloc_cbs)) catch @panic("Failed to initialize texture image");
    const sampler_id = resources.insert(initTextureSampler(engine.logical_device.handle, engine.physical_device)) catch @panic("Failed to initialize texture sampler");

    const meshes = initMeshes(engine.allocs, &engine.upload_context, engine.logical_device, .{
        .image_sampler = .{
            .image_id = image_id,
            .sampler_id = sampler_id,
        },
    });
    defer engine.allocs.std.free(meshes);
    for (meshes) |m|
        _ = resources.insert(m) catch @panic("Failed to initialize meshes");
    return resources;
}

fn initMeshes(
    allocs: core.VulkanEngine.Allocators,
    ctx: *vki.UploadContext,
    logical_device: vki.LogicalDevice,
    /// for now all meshes share a material
    material: ResourceManager.Material,
) []ResourceManager.Resource {
    const vertices_indices = [_]struct { []const mesh_mod.Vertex3D, []const u16 }{
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

    var all_meshes = std.ArrayList(ResourceManager.Resource).initCapacity(allocs.std, 16) catch @panic("OOM");
    for (vertices_indices) |vi| {
        var mesh = mesh_mod.Mesh3D.init(allocs.std, vi.@"0", vi.@"1") catch @panic("OOM");
        mesh.upload(allocs.vma, ctx, logical_device);
        all_meshes.append(allocs.std, .{ .mesh = .{
            .mesh = mesh,
            .material = material,
        } }) catch @panic("OOM");
    }

    {
        const Vertex3DHash = struct {
            pub fn hash(cx: @This(), vertex: mesh_mod.Vertex3D) u64 {
                _ = cx;
                var h: u64 = 0;
                for (std.mem.asBytes(&vertex)) |byte| {
                    h = h *% 31 +% byte;
                }
                return h;
            }

            pub fn eql(cx: @This(), a: mesh_mod.Vertex3D, b: mesh_mod.Vertex3D) bool {
                _ = cx;
                return std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b));
            }
        };
        var viking_room = core.obj_loader.parseFile(allocs.std, "assets/viking_room.obj") catch @panic("failed to read lost_empire.obj");
        defer viking_room.deinit();

        // var uniques = std.AutoHashMap(u64, u16).init(allocs.std);
        var uniques = std.HashMap(mesh_mod.Vertex3D, u16, Vertex3DHash, std.hash_map.default_max_load_percentage).init(allocs.std);
        var indices = std.ArrayList(u16).initCapacity(allocs.std, viking_room.vertices.len) catch @panic("OOM");
        var vertices = std.ArrayList(mesh_mod.Vertex3D).initCapacity(allocs.std, viking_room.vertices.len) catch @panic("OOM");
        defer {
            indices.deinit(allocs.std);
            vertices.deinit(allocs.std);
            uniques.deinit();
        }

        var current_index: u16 = 0;
        for (viking_room.objects) |object| {
            for (object.indices) |idx| {
                var uv = Vec2.fromSizedArray(viking_room.uvs[idx.uv]);
                uv.y = 1.0 - uv.y;

                const vertex = mesh_mod.Vertex3D{
                    .position = Vec3.fromSizedArray(viking_room.vertices[idx.vertex]),
                    .uv = uv,
                    .normal = Vec3.fromSizedArray(viking_room.normals[idx.normal]),
                    .color = Vec3.ZERO,
                };

                // const hash = Vertex3DHash.hash(vertex);
                const entry = uniques.getOrPut(vertex) catch @panic("OOM");

                if (!entry.found_existing) {
                    entry.value_ptr.* = current_index;
                    vertices.append(allocs.std, vertex) catch @panic("OOM");
                    current_index += 1;
                }

                indices.append(allocs.std, entry.value_ptr.*) catch @panic("OOM");
            }
        }

        var mesh = mesh_mod.Mesh3D.init(allocs.std, vertices.items, indices.items) catch @panic("failed to create mesh");
        mesh.upload(allocs.vma, ctx, logical_device);

        all_meshes.append(allocs.std, .{ .mesh = .{
            .mesh = mesh,
            .material = material,
        } }) catch @panic("OOM");
    }

    return all_meshes.toOwnedSlice(allocs.std) catch @panic("OOM");
}

fn initBackgroundDrawImage(
    allocs: core.VulkanEngine.Allocators,
    swapchain: vki.Swapchain,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) ResourceManager.Resource {
    const usages: vk.ImageUsageFlags =
        vk.IMAGE_USAGE_TRANSFER_SRC_BIT |
        vk.IMAGE_USAGE_TRANSFER_DST_BIT |
        vk.IMAGE_USAGE_STORAGE_BIT | vk.IMAGE_USAGE_COLOR_ATTACHMENT_BIT;

    var image = vma_usage.AllocatedImage.init(allocs.vma, core.VulkanEngine.MAIN_RENDER_PASS_IMAGE_FORMAT, vk.Extent3D{
        .width = swapchain.extent.width,
        .height = swapchain.extent.height,
        .depth = 1,
    }, usages);
    const view_ci = vki.imageViewCreateInfo(image.format, image.image, vk.IMAGE_ASPECT_COLOR_BIT);

    checkVk(vk.CreateImageView(device, &view_ci, alloc_cbs, &image.view)) catch @panic("failed to create image view");

    return .{ .image = image };
}

fn initTextureImage(
    allocs: core.VulkanEngine.Allocators,
    ctx: *vki.UploadContext,
    logical_device: vki.LogicalDevice,
    alloc_cbs: ?*vk.AllocationCallbacks,
) ResourceManager.Resource {
    var test_img = texs.loadImageFromFile(allocs.vma, ctx, logical_device, "assets/viking_room.png") catch @panic("Failed to load image");

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
    checkVk(vk.CreateImageView(logical_device.handle, &image_view_ci, alloc_cbs, &test_img.view)) catch @panic("Failed to create image view");

    return .{ .image = test_img };
}

fn initTextureSampler(device: vk.Device, physical_device: vki.PhysicalDevice) ResourceManager.Resource {
    var sampler: vk.Sampler = undefined;
    const ci = vk.SamplerCreateInfo{
        .sType = vk.STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
        .magFilter = vk.FILTER_LINEAR,
        .minFilter = vk.FILTER_LINEAR,
        .addressModeU = vk.SAMPLER_ADDRESS_MODE_REPEAT,
        .addressModeV = vk.SAMPLER_ADDRESS_MODE_REPEAT,
        .addressModeW = vk.SAMPLER_ADDRESS_MODE_REPEAT,
        .anisotropyEnable = vk.TRUE,
        .maxAnisotropy = physical_device.properties.limits.maxSamplerAnisotropy,
        .borderColor = vk.BORDER_COLOR_INT_OPAQUE_BLACK,
        .unnormalizedCoordinates = vk.FALSE,
        .compareEnable = vk.FALSE,
        .compareOp = vk.COMPARE_OP_ALWAYS,
        .mipmapMode = vk.SAMPLER_MIPMAP_MODE_LINEAR,
        .mipLodBias = 0.0,
        .minLod = 0.0,
        .maxLod = 0.0,
    };

    checkVk(vk.CreateSampler(device, &ci, null, &sampler)) catch @panic("failed to create sampler");

    return .{ .sampler = sampler };
}
