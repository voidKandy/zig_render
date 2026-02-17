const std = @import("std");
const sdl = @import("clibs.zig").sdl;

pub const Event = enum {
    KeyDown,
    KeyUp,
    Quit,
    WindowMaximized,
    WindowMinimized,
    WindowResized,
    MouseWheel,
    MouseMotion,

    pub fn from(event: sdl.Event) error{NotRegistered}!Event {
        return switch (event.type) {
            sdl.EVENT_KEY_DOWN => Event.KeyDown,
            sdl.EVENT_KEY_UP => Event.KeyUp,
            sdl.EVENT_QUIT => Event.Quit,
            sdl.EVENT_WINDOW_MAXIMIZED => Event.WindowMaximized,
            sdl.EVENT_WINDOW_MINIMIZED => Event.WindowMinimized,
            sdl.EVENT_WINDOW_RESIZED => Event.WindowResized,
            sdl.EVENT_MOUSE_WHEEL => Event.MouseWheel,
            sdl.EVENT_MOUSE_MOTION => Event.MouseMotion,
            else => return error.NotRegistered,
        };
    }
};
