const std = @import("std");
const log = std.log.scoped(.Input);
const core = @import("../root.zig");
const sdl = core.clibs.sdl;
const sdl_usage = core.bindings.sdl_usage;
const math_mod = core.lib.math;

/// For frame local input snapshots
/// Should be reset via `= .{}` at the beginning of each frame
scroll: f32 = 0.0,
mouse_delta: math_mod.Vec2 = .ZERO,
quit: bool = false,
keys: std.StaticBitSet(std.meta.fields(sdl_usage.KeyCode).len) = .initEmpty(),

pub fn isDown(self: @This(), key: sdl_usage.KeyCode) bool {
    return self.keys.isSet(@intFromEnum(key));
}

pub fn update(self: *@This(), event: sdl.Event) void {
    switch (sdl_usage.Event.from(event) catch return) {
        .Quit => self.quit = true,
        .MouseWheel => self.scroll += event.wheel.y,
        .KeyDown => {
            const key = sdl_usage.KeyCode.from(event.key.key) catch return;
            self.keys.set(@intFromEnum(key));
        },
        .KeyUp => {
            const key = sdl_usage.KeyCode.from(event.key.key) catch return;
            self.keys.unset(@intFromEnum(key));
        },
        .MouseMotion => {
            self.mouse_delta.x += event.motion.xrel;
            self.mouse_delta.y += event.motion.yrel;
        },

        else => {},
    }
}
