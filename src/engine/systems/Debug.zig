const std = @import("std");
const core = @import("../../root.zig");
const log = std.log.scoped(.DebugSystem);
const sdl = core.clibs.sdl;
const vk = core.clibs.vk;
const imgui = core.clibs.imgui;
const Debug = @This();

materials_textures_sets: std.StringHashMapUnmanaged(vk.DescriptorSet) = .empty,
attachment_sets: std.StringHashMapUnmanaged(vk.DescriptorSet) = .empty,

pub fn deinit(
    self: *@This(),
    allocs: core.engine.Allocators,
    _: vk.Device,
    _: ?*vk.AllocationCallbacks,
) void {
    self.materials_textures_sets.deinit(allocs.std);
    self.attachment_sets.deinit(allocs.std);
}

pub fn bind(
    self: *@This(),
    a: std.mem.Allocator,
    resources: *const core.resources.Manager,
    alloc_resources: *const core.resources.Manager.AllocatedData,
) std.mem.Allocator.Error!void {
    for (0..resources.materials.material_indices.size) |i| {
        const name = resources.materials.material_names_reverse_lookup.get(i).?;
        if (std.mem.eql(
            u8,
            name,
            // background image will not be in correct layout, so we dont allow it to be added
            core.engine.systems.DrawBackground.BACKGROUND_IMAGE_NAME,
        )) continue;

        const img = alloc_resources.materials.textures.get(name).?;

        const set = imgui.impl_vulkan.AddTexture(
            alloc_resources.materials.sampler,
            img.view,
            vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        );
        log.debug(
            \\ created set for {s}
        , .{name});
        try self.materials_textures_sets.put(a, name, set);
    }
}

pub fn bindAttachments(
    self: *@This(),
    a: std.mem.Allocator,
    swapchain: *const core.engine.Renderer.Swapchain,
    alloc_resources: *const core.resources.Manager.AllocatedData,
) std.mem.Allocator.Error!void {
    self.attachment_sets.clearRetainingCapacity();
    const Attachments = core.engine.Renderer.Swapchain.Attachments;
    inline for (Attachments.ALL_TAGS) |tag| {
        if (tag != .final) {
            const att = @field(swapchain.attachments.plexe, @tagName(tag));
            const layout = if (tag == .depth)
                vk.IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL
            else
                vk.IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            const set = imgui.impl_vulkan.AddTexture(
                alloc_resources.materials.sampler,
                att.image.view,
                layout,
            );
            const name = @tagName(tag) ++ " attachment";
            log.debug(
                \\ created set for {s} 
            , .{name});
            try self.attachment_sets.put(a, name, set);
        }
    }
}

pub fn drawImgui(self: *@This(), ctx: core.engine.systems.manager.DrawImguiContext) void {
    var open = true;
    // const window = engine.window;
    const shown = imgui.Begin("Debug", &open, core.clibs.imgui.WINDOW_ALWAYS_AUTO_RESIZE);
    defer imgui.End();
    if (!shown) return;

    const is_relative_mouse = sdl.GetWindowRelativeMouseMode(ctx.window) == true;
    imgui.Text(if (is_relative_mouse) "Mouse: Relative" else "Mouse: Absolute");
    imgui.Text("Press escape to toggle mouse mode");

    var iter = self.materials_textures_sets.iterator();
    while (iter.next()) |entry| {
        var buf: [64]u8 = undefined;
        const zbuf = std.fmt.bufPrintSentinel(&buf, "{s}", .{entry.key_ptr.*}, 0) catch @panic("Buffer couldnt print??");
        imgui.Text(zbuf);
        imgui.Image(entry.value_ptr.*, imgui.ImVec2{ .x = 400, .y = 400 });
    }

    iter = self.attachment_sets.iterator();
    while (iter.next()) |entry| {
        var buf: [64]u8 = undefined;
        const zbuf = std.fmt.bufPrintSentinel(&buf, "{s}", .{entry.key_ptr.*}, 0) catch @panic("Buffer couldnt print??");
        imgui.Text(zbuf);
        imgui.Image(entry.value_ptr.*, imgui.ImVec2{ .x = 400, .y = 400 });
    }
}
