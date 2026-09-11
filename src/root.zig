//! core Library for zig render
const std = @import("std");
pub const clibs = @import("clibs/root.zig");

pub const bindings = struct {
    pub const vma_usage = @import("bindings/vma_usage.zig");
    pub const sdl_usage = @import("bindings/sdl_usage.zig");
    pub const vulkan_init = @import("bindings/vulkan_init.zig");
    pub const vulkan_util = @import("bindings/vulkan_util.zig");
    test {
        std.testing.refAllDecls(@This());
    }
};

pub const engine = struct {
    pub const Allocators = struct {
        std: std.mem.Allocator,
        vma: clibs.vma.Allocator = undefined,
    };

    pub const Camera = @import("engine/Camera.zig");
    pub const world = @import("engine/world.zig");
    pub const Engine = @import("engine/Engine.zig");
    pub const frames = @import("engine/frames.zig");
    pub const Input = @import("engine/Input.zig");
    pub const shaders = @import("engine/shaders.zig");

    pub const systems = struct {
        pub const Manager = @import("engine/systems/Manager.zig");
        pub const MeshManipulation = @import("engine/systems/MeshManipulation.zig");
        pub const Maze = @import("engine/systems/Maze.zig");
        pub const Camera = @import("engine/systems/Camera.zig");
        pub const DrawBackground = @import("engine/systems/DrawBackground.zig");
    };

    pub const graphics_pipelines = struct {
        pub const Mesh3DPipeline = @import("engine/pipelines/Mesh3DPipeline.zig");
        pub const Mesh2DPipeline = @import("engine/pipelines/Mesh2DPipeline.zig");

        const DefaultDescriptorSets =
            enum {
                camera,
                samplers,
                texture,
                meshes,
            };

        pub const DefaultDescription = Description(DefaultDescriptorSets);

        pub fn Description(DescriptorSets: type) type {
            _ = @typeInfo(DescriptorSets).@"enum";

            return struct {
                pub const Layouts = std.EnumArray(DescriptorSets, clibs.vk.DescriptorSetLayout);
                pub const Sets = std.EnumArray(DescriptorSets, clibs.vk.DescriptorSet);

                layouts: Layouts,
                device: clibs.vk.Device,
                render_pass: clibs.vk.RenderPass,
                window_extent: clibs.vk.Extent2D,
                vertex_shader: clibs.vk.ShaderModule,
                fragment_shader: clibs.vk.ShaderModule,
                depth_compare_op: ?clibs.vk.CompareOp,

                pub fn createPipelineLayout(
                    self: @This(),
                    PushConstants: ?type,
                    alloc_cbs: ?*clibs.vk.AllocationCallbacks,
                ) clibs.vk.PipelineLayout {
                    var layout: clibs.vk.PipelineLayout = undefined;
                    var ci = clibs.vk.PipelineLayoutCreateInfo{
                        .sType = clibs.vk.STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
                        .setLayoutCount = self.layouts.values.len,
                        .pSetLayouts = &self.layouts.values,
                    };

                    if (PushConstants) |P| {
                        const push_constant = clibs.vk.PushConstantRange{
                            .offset = 0,
                            .size = @sizeOf(P),
                            // THIS MAY NEED TO BE MORE CONFIGURABLE
                            .stageFlags = clibs.vk.SHADER_STAGE_VERTEX_BIT,
                        };
                        ci.pushConstantRangeCount = 1;
                        ci.pPushConstantRanges = &push_constant;
                    }

                    bindings.vulkan_init.checkVk(clibs.vk.CreatePipelineLayout(
                        self.device,
                        &ci,
                        alloc_cbs,
                        &layout,
                    )) catch
                        @panic("failed to create pipeline layout");

                    return layout;
                }
            };
        }

        test {
            std.testing.refAllDecls(@This());
        }
    };

    test {
        std.testing.refAllDecls(@This());
    }
};

pub const lib = struct {
    pub const ecs = @import("lib/ecs.zig");
    pub const math = @import("lib/math.zig");
    pub const Maze = @import("lib/Maze.zig");
    pub const mesh = @import("lib/mesh.zig");
    pub const terrain = @import("lib/terrain.zig");
    // pub const alpha_wrapping = @import("lib/alpha_wrapping.zig");
    pub const delaunay = @import("lib/delaunay.zig");
    test {
        std.testing.refAllDecls(@This());
    }
};

pub const loaders = struct {
    pub const obj = @import("loaders/obj.zig");
    pub const mtl = @import("loaders/mtl.zig");
    test {
        std.testing.refAllDecls(@This());
    }
};

pub const resources = struct {
    pub const Manager = @import("resources/Manager.zig");
    pub const MappedBuffers = @import("resources/MappedBuffers.zig");
    pub const Materials = @import("resources/Materials.zig");
    pub const Meshes2D = @import("resources/Meshes2D.zig");
    pub const Meshes3D = @import("resources/Meshes3D.zig");
    test {
        std.testing.refAllDecls(@This());
    }
};

test {
    std.testing.refAllDecls(@This());
}
