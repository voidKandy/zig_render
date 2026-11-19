const std = @import("std");
const core = @import("../root.zig");
const log = std.log.scoped(.pipelines);
const clibs = core.clibs;
const bindings = core.bindings;
const Renderer = core.engine.Renderer;

const DescriptionOptions = struct {
    /// Should be an enum type
    /// sets will be in order of the variants
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

/// Helper function for describing both graphics and compute pipelines
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
