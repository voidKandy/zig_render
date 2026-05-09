const vk = @import("../root.zig").clibs.vk;

pub const GraphicsPipeline = @import("GraphicsPipeline.zig");
pub const ComputePipeline = @import("ComputePipeline.zig");

//// BAD ALL BELOW DEPRECATED AND MUST BE REMOVED
// pub const Triangle = @import("Triangle.zig");
// pub const Scene3D = @import("Scene3D.zig");
// pub const BackgroundEffects = @import("BackgroundEffects.zig");
// pub const PipelineManager = @import("PipelineManager.zig");

pub const RangeDesc = struct {
    offset: vk.DeviceSize = 0,
    range: vk.DeviceSize = 0,
};

pub const TextureInfo = struct {
    sampler: vk.Sampler,
    image_view: vk.ImageView,
};
// currently this function has a silent requirement that the resources of the engine have been initialized
// This function then associates those resources with the pipelines they are meant for
// pub fn initPipelines(engine: *VulkanEngine) anyerror!PipelineManager {
//     var all_pipelines = PipelineManager.init(engine.allocs.std);

//     const init_data = Pipeline.InitData{
//         .main_render_pass = engine.main_render_pass,
//         .swapchain_extent = engine.swapchain.extent,
//         .descriptor_set_layout = engine.descriptor_set_layout,
//         .resources = engine.resources,
//     };

//     {
//         // var entry = PipelineObject.create(tools.Triangle, engine.allocs.std) catch @panic("OOM");
//         // const resources = &[_]ResourceManager.ResourceID{engine.resources.getId(.mesh3D, 0).?};
//         // entry.init(
//         //     &engine.allocs,
//         //     init_data,
//         //     resources,
//         //     engine.logical_device,
//         //     engine.alloc_cbs,
//         // );
//         // pipeline_objects.insert(engine.allocs.std, .graphics, "meshes", "triangle", entry) catch @panic("OOM");
//     }

//     {
//         const mesh_count = init_data.resources.mesh_manager.count;
//         var resources = try engine.allocs.std.alloc(ResourceManager.ResourceID, mesh_count + 1);
//         defer engine.allocs.std.free(resources);

//         var j: usize = 0;
//         // we skip mesh 0 because that is triangle
//         // BAD
//         for (1..mesh_count) |i| {
//             resources[j] = engine.resources.getId(.mesh, i).?;
//             j += 1;
//         }
//         resources[j] = engine.resources.getId(.image, 0).?;
//         j += 1;
//         resources[j] = engine.resources.getId(.sampler, 0).?;

//         var entry = Pipeline.create(Scene3D, engine.allocs.std) catch @panic("OOM");
//         entry.init(
//             &engine.allocs,
//             init_data,
//             resources,
//             engine.logical_device,
//             engine.alloc_cbs,
//         );
//         all_pipelines.insert(engine.allocs.std, .graphics, "meshes", "scene3D", entry) catch @panic("OOM");
//     }

//     {
//         const background_image = engine.resources.getId(.image, 0).?;
//         var entry = Pipeline.create(BackgroundEffects, engine.allocs.std) catch @panic("OOM");
//         entry.init(
//             &engine.allocs,
//             init_data,
//             &[_]ResourceManager.ResourceID{background_image},
//             engine.logical_device,
//             engine.alloc_cbs,
//         );
//         all_pipelines.insert(engine.allocs.std, .compute, "background_image", null, entry) catch @panic("OOM");
//     }

//     return all_pipelines;
// }
