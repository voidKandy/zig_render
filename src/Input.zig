const std = @import("std");
const log = std.log.scoped(.Input);
const sdl = @import("clibs.zig").sdl;
const sdl_usage = @import("sdl_usage.zig");
const math = @import("math3d.zig");

/// For frame local input snapshots
/// Should be reset via `= .{}` at the beginning of each frame
scroll: f32 = 0.0,
mouse_delta: math.Vec2 = .ZERO,
quit: bool = false,

pub fn update(self: *@This(), event: sdl.Event) void {
    switch (sdl_usage.Event.from(event) catch return) {
        .Quit => self.quit = true,
        .MouseWheel => self.scroll += event.wheel.y,
        else => {},
    }
}
