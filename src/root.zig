//! core Library for zig render
const std = @import("std");
pub const clibs = @import("clibs/root.zig");

pub const bindings = struct {
    pub const vma_usage = @import("bindings/vma_usage.zig");
    pub const sdl_usage = @import("bindings/sdl_usage.zig");
    pub const vulkan_init = @import("bindings/vulkan_init.zig");
    pub const box3d_usage = @import("bindings/box3d_usage.zig");
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

    pub const frames = @import("engine/frames.zig");
    pub const shaders = @import("engine/shaders.zig");
    pub const world = @import("engine/world.zig");
    pub const Engine = @import("engine/Engine.zig");
    pub const Input = @import("engine/Input.zig");
    pub const Physics = @import("engine/Physics.zig");
    pub const Renderer = @import("engine/rendering/Manager.zig");

    pub const systems = struct {
        pub const manager = @import("engine/systems/manager.zig");
        pub const Maze = @import("engine/systems/Maze.zig");
        pub const Debug = @import("engine/systems/Debug.zig");
        pub const Camera = @import("engine/systems/Camera.zig");
        pub const DrawBackground = @import("engine/systems/DrawBackground.zig");
        test {
            std.testing.refAllDecls(@This());
        }
    };

    pub const pipelines = struct {
        const DescriptionOptions = struct {
            DescriptorSets: type,
            /// passed as null when used for compute pipelines
            subpass_idx: ?u32,
            input_attachments: ?std.EnumSet(Renderer.Attachments.Tags) = null,
            color_attachments: ?std.EnumSet(Renderer.Attachments.Tags) = null,
            depth_attachment: ?Renderer.Attachments.Tags = null,
            push_constants: ?struct {
                type,
                clibs.vk.ShaderStageFlags,
            } = null,
        };

        pub const Common = struct {
            device: clibs.vk.Device,
            render_pass: clibs.vk.RenderPass,
            window_extent: clibs.vk.Extent2D,
        };

        pub fn Description(comptime opts: DescriptionOptions) type {
            _ = @typeInfo(opts.DescriptorSets).@"enum";
            comptime {
                var has_input_attachments = false;

                for (@typeInfo(opts.DescriptorSets).@"enum".field_names) |name| {
                    if (std.mem.eql(u8, name, "input_attachments")) {
                        has_input_attachments = true;
                        break;
                    }
                }

                if (has_input_attachments and opts.input_attachments == null)
                    @compileError("input_attachments set must be provided!");

                if (opts.depth_attachment) |da| {
                    if (!Renderer.Attachments.isDepthAttachment(da))
                        @compileError("Passed a non-depth attachment as depth attachment");
                }
            }
            return struct {
                pub const Layouts = std.EnumArray(opts.DescriptorSets, clibs.vk.DescriptorSetLayout);
                pub const Sets = std.EnumArray(opts.DescriptorSets, clibs.vk.DescriptorSet);
                pub const OPTIONS = opts;
                pub const AttachmentReferences = struct {
                    input: [if (OPTIONS.input_attachments) |a| a.count() else 0]clibs.vk.AttachmentReference,
                    color: [if (OPTIONS.color_attachments) |a| a.count() else 0]clibs.vk.AttachmentReference,
                    depth: ?clibs.vk.AttachmentReference,
                };

                layouts: Layouts,
                common: Common,
                shader: clibs.vk.ShaderModule,

                pub fn getAttachmentReferences() AttachmentReferences {
                    var input: [if (OPTIONS.input_attachments) |a| a.count() else 0]clibs.vk.AttachmentReference = undefined;
                    var color: [if (OPTIONS.color_attachments) |a| a.count() else 0]clibs.vk.AttachmentReference = undefined;
                    var depth: ?clibs.vk.AttachmentReference = null;

                    if (OPTIONS.input_attachments) |set| {
                        var iter = set.iterator();
                        var i: usize = 0;
                        while (iter.next()) |tag| : (i += 1) {
                            input[i] = .{
                                .attachment = Renderer.Attachments.attachmentIdx(tag),
                                .layout = if (Renderer.Attachments.isDepthAttachment(tag))
                                    clibs.vk.IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL
                                else
                                    clibs.vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                            };
                        }
                    }
                    if (OPTIONS.color_attachments) |set| {
                        var iter = set.iterator();
                        var i: usize = 0;
                        while (iter.next()) |tag| : (i += 1) {
                            color[i] = .{
                                .attachment = Renderer.Attachments.attachmentIdx(tag),
                                .layout = if (Renderer.Attachments.isDepthAttachment(tag))
                                    clibs.vk.IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL
                                else
                                    clibs.vk.IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
                            };
                        }
                    }
                    if (OPTIONS.depth_attachment) |tag| {
                        depth = .{
                            .attachment = Renderer.Attachments.attachmentIdx(tag),
                            .layout = clibs.vk.IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
                        };
                    }

                    return .{
                        .color = color,
                        .input = input,
                        .depth = depth,
                    };
                }
                pub fn createPipelineLayout(
                    layouts: Layouts,
                    device: clibs.vk.Device,
                    alloc_cbs: ?*clibs.vk.AllocationCallbacks,
                ) clibs.vk.PipelineLayout {
                    var layout: clibs.vk.PipelineLayout = undefined;
                    var ci = clibs.vk.PipelineLayoutCreateInfo{
                        .sType = clibs.vk.STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
                        .setLayoutCount = layouts.values.len,
                        .pSetLayouts = &layouts.values,
                    };

                    if (opts.push_constants) |pc_opts| {
                        const push_constant = clibs.vk.PushConstantRange{
                            .offset = 0,
                            .size = @sizeOf(pc_opts.@"0"),
                            .stageFlags = pc_opts.@"1",
                        };
                        ci.pushConstantRangeCount = 1;
                        ci.pPushConstantRanges = &push_constant;
                    }

                    bindings.vulkan_init.checkVk(clibs.vk.CreatePipelineLayout(
                        device,
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
    pub const alpha_wrapping = struct {
        pub const Delaunay = @import("lib/alpha_wrapping/Delaunay.zig");
        pub const Wrap = @import("lib/alpha_wrapping/Wrap.zig");
        pub const Oracle = @import("lib/alpha_wrapping/Oracle.zig");
        test {
            std.testing.refAllDecls(@This());
        }
    };

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
