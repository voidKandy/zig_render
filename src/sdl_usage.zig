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

pub const KeyCode = enum {
    Num0,
    Num1,
    Num2,
    Num3,
    Num4,
    Num5,
    Num6,
    Num7,
    Num8,
    Num9,
    W,
    A,
    S,
    D,

    pub fn from(key: sdl.Keycode) error{NotRegistered}!@This() {
        return switch (key) {
            sdl.K_0 => .Num0,
            sdl.K_1 => .Num1,
            sdl.K_2 => .Num2,
            sdl.K_3 => .Num3,
            sdl.K_4 => .Num4,
            sdl.K_5 => .Num5,
            sdl.K_6 => .Num6,
            sdl.K_7 => .Num7,
            sdl.K_8 => .Num8,
            sdl.K_9 => .Num9,
            sdl.K_W => .W,
            sdl.K_A => .A,
            sdl.K_S => .S,
            sdl.K_D => .D,
            else => error.NotRegistered,
        };
    }
};
