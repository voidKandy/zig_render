const std = @import("std");
const core = @import("../../root.zig");
const log = std.log.scoped(.DebugSystem);
const sdl = core.clibs.sdl;
const vk = core.clibs.vk;
const imgui = core.clibs.imgui;
const Debug = @This();

materials_textures_sets: std.StringHashMapUnmanaged(vk.DescriptorSet) = .empty,

pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
    self.materials_textures_sets.deinit(a);
}

pub fn bind(
    self: *@This(),
    a: std.mem.Allocator,
    resources: core.resources.Manager,
    alloc_resources: core.resources.Manager.AllocatedData,
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

// pub fn update(
//     self: *@This(),
// ) void {}

// pub fn trySyncResources(
//     self: *@This(),
//     resources: core.resources.Manager,
//     alloc_resources: core.resources.Manager.AllocatedData,
//     world: *core.engine.world.GameWorld,
// ) void {}

pub fn drawImgui(
    self: *@This(),
    window: *sdl.Window,
) void {
    var open = true;
    const shown = imgui.Begin("Debug", &open, core.clibs.imgui.WINDOW_ALWAYS_AUTO_RESIZE);
    defer imgui.End();
    if (!shown) return;

    const is_relative_mouse = sdl.GetWindowRelativeMouseMode(window) == true;
    imgui.Text(if (is_relative_mouse) "Mouse: Relative" else "Mouse: Absolute");
    imgui.Text("Press escape to toggle mouse mode");

    var iter = self.materials_textures_sets.iterator();
    while (iter.next()) |entry| {
        var buf: [64]u8 = undefined;
        const zbuf = std.fmt.bufPrintZ(&buf, "{s}", .{entry.key_ptr.*}) catch @panic("Buffer couldnt print??");
        imgui.Text(zbuf);
        imgui.Image(entry.value_ptr.*, imgui.ImVec2{ .x = 400, .y = 400 });
    }
}
