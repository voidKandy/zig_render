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
const pipelines = @import("pipelines");
const mesh_mod = core.mesh;
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

fn createCameraDataDescriptorSet(device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) vk.DescriptorSet {
    var layout: vk.DescriptorSetLayout = undefined;
    // const frame_sizes = &[_]descriptor.Allocator.PoolSizeRatio{
    //     .{ vk.DESCRIPTOR_TYPE_STORAGE_IMAGE, 3 },
    //     .{ vk.DESCRIPTOR_TYPE_STORAGE_BUFFER, 3 },
    //     .{ vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER, 3 },
    //     .{ vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 4 },
    // };
    // for (self.all) |frame| {
    //     frame.descriptors = descriptor.Allocator.init(a, vk_alloc_cbs, device, 1000, frame_sizes);
    // }

    const ubo_layout_binding = vk.DescriptorSetLayoutBinding{
        .binding = 0,
        .descriptorCount = 1,
        .descriptorType = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .stageFlags = vk.SHADER_STAGE_VERTEX_BIT,
        .pImmutableSamplers = null,
    };
    const sampler_layout_binding = vk.DescriptorSetLayoutBinding{
        .binding = 1,
        .descriptorCount = 1,
        .descriptorType = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
        .stageFlags = vk.SHADER_STAGE_FRAGMENT_BIT,
        .pImmutableSamplers = null,
    };

    const bindings = &[_]vk.DescriptorSetLayoutBinding{ ubo_layout_binding, sampler_layout_binding };

    const ci = vk.DescriptorSetLayoutCreateInfo{
        .sType = vk.STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .bindingCount = bindings.len,
        .pBindings = bindings,
    };

    checkVk(vk.CreateDescriptorSetLayout(device, &ci, alloc_cbs, &layout)) catch @panic("failed to create descriptor set layout");
}

fn initDescriptors(engine: *core.VulkanEngine) std.mem.Allocator.Error!std.StringHashMap(BoundDescriptor) {
    var map = std.StringHashMap(BoundDescriptor).init(engine.allocs.std);

    var builder = core.descriptor.LayoutBuilder.init(engine.allocs.std);
    defer builder.deinit(engine.allocs.std);
    builder.addBinding(engine.allocs.std, 0, vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER);
    const camera_data_layout = builder.build(engine.logical_device.handle, vk.SHADER_STAGE_VERTEX_BIT, null, 0, engine.alloc_cbs);
    const camera_data_set = engine.allocs.global_descriptor.allocate(engine.logical_device.handle, camera_data_layout, null);

    const bound = BoundDescriptor.init(
        core.frames.GPUCameraData,
        engine.allocs.vma,
        camera_data_set,
        camera_data_layout,
        &rotateCamera,
    );
    try map.put("camera_data", bound);

    const camera_data_info = vk.DescriptorBufferInfo{
        .buffer = bound.data.buffer,
        .offset = 0,
        .range = @sizeOf(core.frames.GPUCameraData),
    };

    const camera_data_write = vk.WriteDescriptorSet{
        .dstBinding = 0,
        .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
        .dstSet = camera_data_set,
        .dstArrayElement = 0,
        .descriptorType = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
        .descriptorCount = 1,
        .pBufferInfo = &camera_data_info,
    };

    // const img_info = vk.DescriptorImageInfo{
    //     .imageLayout = vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    //     .imageView = texture_image_view,
    //     .sampler = texture_sampler,
    // };

    // const img_write = vk.WriteDescriptorSet{
    //     .dstBinding = 1,
    //     .sType = vk.STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET,
    //     .dstSet = frame.camera_data.descriptor_set,
    //     .dstArrayElement = 0,
    //     .descriptorType = vk.DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER,
    //     .descriptorCount = 1,
    //     .pImageInfo = &img_info,
    // };

    const writes = &[_]vk.WriteDescriptorSet{
        camera_data_write,
        // img_write
    };

    vk.UpdateDescriptorSets(engine.logical_device.handle, writes.len, writes, 0, null);

    return map;
}

fn rotateCamera(engine: core.VulkanEngine, desc: *BoundDescriptor) void {
    const State = struct {
        var start: i128 = 0;
    };

    // If first call, initialize start time
    if (State.start == 0) {
        State.start = std.time.nanoTimestamp();
    }

    const now = std.time.nanoTimestamp();
    const delta_ns = now - State.start;
    const time: f32 = @as(f32, (@floatFromInt(delta_ns))) / @as(f32, (@floatFromInt(std.time.ns_per_s)));

    const fov = 45.0;
    const near_plane = 0.1;
    const far_plane = 10.0;

    const aspect =
        @as(f32, @floatFromInt(engine.swapchain.extent.width)) /
        @as(f32, @floatFromInt(engine.swapchain.extent.height));
    var ubo = core.frames.GPUCameraData{
        .model = Mat4.IDENTITY.rotate(Vec3.make(0.0, 0.0, 1.0), time * 1.0),
        .view = Mat4.lookAt(Vec3.make(2.0, 2.0, 2.0), Vec3.make(0.0, 0.0, 0.0), Vec3.make(0.0, 0.0, 1.0)),
        .proj = Mat4.perspective(fov, aspect, near_plane, far_plane),
    };

    ubo.proj.j.y *= -1;

    const aligned_data: *core.frames.GPUCameraData = @ptrCast(@alignCast(desc.mapped));
    aligned_data.* = ubo;
}

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
        &initPipelineObjects,
    );
    defer engine.deinit();

    engine.run();
}

fn initResources(engine: *core.VulkanEngine) anyerror!ResourceManager {
    var resources = core.ResourceManager.init(engine.allocs.std) catch @panic("OOM");

    const meshes = initMeshes(engine.allocs, &engine.upload_context, engine.logical_device);
    defer engine.allocs.std.free(meshes);
    for (meshes) |m|
        _ = resources.insert(m) catch @panic("Failed to initialize meshes");

    _ = resources.insert(initBackgroundDrawImage(engine.allocs, engine.swapchain, engine.logical_device.handle, engine.alloc_cbs)) catch @panic("Failed to initialize background draw image");
    _ = resources.insert(initTextureImage(engine.allocs, &engine.upload_context, engine.logical_device, engine.alloc_cbs)) catch @panic("Failed to initialize texture image");
    _ = resources.insert(initTextureSampler(engine.logical_device.handle, engine.physical_device)) catch @panic("Failed to initialize texture sampler");
    return resources;
}

fn initPipelineObjects(engine: *core.VulkanEngine) anyerror!PipelineObjManager {
    var pipeline_objects = PipelineObjManager.init(engine.allocs.std);

    const init_data = PipelineObject.InitData{
        .main_render_pass = engine.main_render_pass,
        .swapchain_extent = engine.swapchain.extent,
        .descriptors = engine.bound_descriptors,
        .resources = engine.resources,
    };

    {
        var entry = PipelineObject.create(pipelines.Triangle, engine.allocs.std) catch @panic("OOM");
        const resources = &[_]ResourceManager.ResourceID{engine.resources.getId(.mesh3D, 0).?};
        entry.init(
            &engine.allocs,
            init_data,
            resources,
            engine.logical_device,
            engine.alloc_cbs,
        );
        pipeline_objects.insert(engine.allocs.std, .graphics, "meshes", "triangle", entry) catch @panic("OOM");
    }

    {
        const count = init_data.resources.mesh3D_manager.count;

        var resources = try engine.allocs.std.alloc(ResourceManager.ResourceID, count - 1);
        defer engine.allocs.std.free(resources);

        for (1..count, 0..) |i, j| {
            resources[j] = engine.resources.getId(.mesh3D, i).?;
        }

        var entry = PipelineObject.create(pipelines.Scene3D, engine.allocs.std) catch @panic("OOM");
        entry.init(
            &engine.allocs,
            init_data,
            resources,
            engine.logical_device,
            engine.alloc_cbs,
        );
        pipeline_objects.insert(engine.allocs.std, .graphics, "meshes", "scene3D", entry) catch @panic("OOM");
    }

    {
        const background_image = engine.resources.getId(.image, 0).?;
        var entry = PipelineObject.create(pipelines.BackgroundEffects, engine.allocs.std) catch @panic("OOM");
        entry.init(
            &engine.allocs,
            init_data,
            &[_]ResourceManager.ResourceID{background_image},
            engine.logical_device,
            engine.alloc_cbs,
        );
        pipeline_objects.insert(engine.allocs.std, .compute, "background_image", null, entry) catch @panic("OOM");
    }

    return pipeline_objects;
}

fn initMeshes(
    allocs: core.VulkanEngine.Allocators,
    ctx: *vki.UploadContext,
    logical_device: vki.LogicalDevice,
) []ResourceManager.Resource {
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

    const all_meshes = allocs.std.alloc(ResourceManager.Resource, vertices_indices.len) catch @panic("OOM");
    for (all_meshes, vertices_indices) |*m, vi| {
        var mesh = mesh_mod.Mesh3D.init(allocs.std, vi.@"0", vi.@"1") catch @panic("OOM");
        mesh.upload(allocs.vma, ctx, logical_device);
        m.* = .{ .mesh3D = mesh };
    }

    return all_meshes;
}

fn initBackgroundDrawImage(
    allocs: core.VulkanEngine.Allocators,
    swapchain: vki.Swapchain,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) ResourceManager.Resource {
    var image: vma_usage.AllocatedImage = undefined;
    image.format = core.VulkanEngine.MAIN_RENDER_PASS_IMAGE_FORMAT;
    image.extent = vk.Extent3D{
        .width = swapchain.extent.width,
        .height = swapchain.extent.height,
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

    checkVk(c.vma.CreateImage(allocs.vma, &ci, &ai, &image.image, &image.allocation, null)) catch
        @panic("failed to create draw image");

    //build a image-view for the draw image to use for rendering
    const render_view_info = vki.imageViewCreateInfo(image.format, image.image, vk.IMAGE_ASPECT_COLOR_BIT);

    checkVk(vk.CreateImageView(device, &render_view_info, alloc_cbs, &image.view)) catch @panic("failed to create image view");

    return .{ .image = image };
}

/// Currently unused
fn initTextureImage(
    allocs: core.VulkanEngine.Allocators,
    ctx: *vki.UploadContext,
    logical_device: vki.LogicalDevice,
    alloc_cbs: ?*vk.AllocationCallbacks,
) ResourceManager.Resource {
    const test_img = texs.loadImageFromFile(allocs.vma, ctx, logical_device, "assets/test_img.jpg") catch @panic("Failed to load image");

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

    checkVk(vk.CreateImageView(logical_device.handle, &image_view_ci, alloc_cbs, &lost_empire.image_view)) catch @panic("Failed to create image view");

    return .{ .texture = lost_empire };
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
