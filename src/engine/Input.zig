const std = @import("std");
const log = std.log.scoped(.Input);
const core = @import("../root.zig");
const sdl = core.clibs.sdl;
const imgui = core.clibs.imgui;
const sdl_usage = core.bindings.sdl_usage;
const math_mod = core.lib.math;

scroll: f32 = 0.0,
mouse_delta: math_mod.Vec2 = .ZERO,
quit: bool = false,
keys: std.EnumSet(sdl_usage.KeyCode) = .empty,

pub fn isDown(self: @This(), key: sdl_usage.KeyCode) bool {
    return self.keys.contains(key);
}

pub fn update(self: *@This(), event: sdl.Event) void {
    switch (sdl_usage.Event.from(event) catch return) {
        .Quit => self.quit = true,
        .MouseWheel => {
            if (!imgui.GetIO().*.WantCaptureMouse) {
                self.scroll += event.wheel.y;
            }
        },
        .KeyDown => {
            const key = std.enums.fromInt(sdl_usage.KeyCode, event.key.key) orelse return;
            self.keys.insert(key);
        },
        .KeyUp => {
            const key = std.enums.fromInt(sdl_usage.KeyCode, event.key.key) orelse return;
            self.keys.remove(key);
        },
        .MouseMotion => {
            self.mouse_delta.x += event.motion.xrel;
            self.mouse_delta.y += event.motion.yrel;
        },

        else => {},
    }
}
