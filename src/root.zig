//! core Library for zig render
const std = @import("std");
const sdl = clibs.sdl;
pub const shaders = @import("shaders.zig");
pub const mesh = @import("mesh.zig");
pub const frames = @import("frames.zig");
pub const math = @import("math3d.zig");
pub const textures = @import("textures.zig");
pub const descriptor = @import("descriptor.zig");
pub const ResourceManager = @import("ResourceManager.zig");
pub const PipelineObject = @import("PipelineObject.zig");
pub const BoundDescriptor = @import("BoundDescriptor.zig");
pub const PipelineObjManager = @import("PipelineObjManager.zig");
pub const PipelineBuilder = @import("PipelineBuilder.zig");
pub const obj_loader = @import("obj_loader.zig");
pub const clibs = @import("clibs.zig");
pub const vma_usage = @import("vma_usage.zig");
pub const vulkan_init = @import("vulkan_init.zig");
pub const vulkan_util = @import("vulkan_util.zig");
pub const VulkanEngine = @import("VulkanEngine.zig");

pub const pipelines = struct {
    pub const Triangle = @import("pipelines/Triangle.zig");
    pub const Scene3D = @import("pipelines/Scene3D.zig");
    pub const BackgroundEffects = @import("pipelines/BackgroundEffects.zig");

    pub fn initPipelines(engine: *VulkanEngine) anyerror!PipelineObjManager {
        var all_pipelines = PipelineObjManager.init(engine.allocs.std);

        const init_data = PipelineObject.InitData{
            .main_render_pass = engine.main_render_pass,
            .swapchain_extent = engine.swapchain.extent,
            .descriptor_set_layout = engine.descriptor_set_layout,
            .resources = engine.resources,
        };

        {
            // var entry = PipelineObject.create(tools.Triangle, engine.allocs.std) catch @panic("OOM");
            // const resources = &[_]ResourceManager.ResourceID{engine.resources.getId(.mesh3D, 0).?};
            // entry.init(
            //     &engine.allocs,
            //     init_data,
            //     resources,
            //     engine.logical_device,
            //     engine.alloc_cbs,
            // );
            // pipeline_objects.insert(engine.allocs.std, .graphics, "meshes", "triangle", entry) catch @panic("OOM");
        }

        {
            const mesh_count = init_data.resources.mesh_manager.count;
            var resources = try engine.allocs.std.alloc(ResourceManager.ResourceID, mesh_count + 1);
            defer engine.allocs.std.free(resources);

            var j: usize = 0;
            // we skip mesh 0 because that is triangle
            // BAD
            for (1..mesh_count) |i| {
                resources[j] = engine.resources.getId(.mesh, i).?;
                j += 1;
            }
            resources[j] = engine.resources.getId(.image, 0).?;
            j += 1;
            resources[j] = engine.resources.getId(.sampler, 0).?;

            var entry = PipelineObject.create(pipelines.Scene3D, engine.allocs.std) catch @panic("OOM");
            entry.init(
                &engine.allocs,
                init_data,
                resources,
                engine.logical_device,
                engine.alloc_cbs,
            );
            all_pipelines.insert(engine.allocs.std, .graphics, "meshes", "scene3D", entry) catch @panic("OOM");
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
            all_pipelines.insert(engine.allocs.std, .compute, "background_image", null, entry) catch @panic("OOM");
        }

        return all_pipelines;
    }
};

/// Panics if returned bool == false
pub fn checkSdl(res: bool) void {
    if (!res) {
        std.log.err("Detected SDL error: {s}", .{sdl.GetError()});
        @panic("SDL error");
    }
}

pub const UniformBufferObject = struct {
    model: math.Mat4,
    view: math.Mat4,
    proj: math.Mat4,
};

test {
    std.testing.refAllDecls(@This());
}
