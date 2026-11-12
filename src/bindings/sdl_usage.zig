const std = @import("std");
const sdl = @import("../clibs/root.zig").sdl;

/// Panics if returned bool == false
pub fn checkSdl(res: bool) void {
    if (!res) {
        std.log.err("Detected SDL error: {s}", .{sdl.GetError()});
        @panic("SDL error");
    }
}

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

/// For extending
/// https://www.libsdl.org/release/SDL-1.2.15/docs/html/sdlkey.html
pub const KeyCode = enum(sdl.Keycode) {
    Num0 = sdl.K_0,
    Num1 = sdl.K_1,
    Num2 = sdl.K_2,
    Num3 = sdl.K_3,
    Num4 = sdl.K_4,
    Num5 = sdl.K_5,
    Num6 = sdl.K_6,
    Num7 = sdl.K_7,
    Num8 = sdl.K_8,
    Num9 = sdl.K_9,
    A = sdl.K_A,
    B = sdl.K_B,
    C = sdl.K_C,
    D = sdl.K_D,
    E = sdl.K_E,
    F = sdl.K_F,
    G = sdl.K_G,
    H = sdl.K_H,
    I = sdl.K_I,
    J = sdl.K_J,
    K = sdl.K_K,
    L = sdl.K_L,
    M = sdl.K_M,
    N = sdl.K_N,
    O = sdl.K_O,
    P = sdl.K_P,
    Q = sdl.K_Q,
    R = sdl.K_R,
    S = sdl.K_S,
    T = sdl.K_T,
    U = sdl.K_U,
    V = sdl.K_V,
    W = sdl.K_W,
    X = sdl.K_X,
    Y = sdl.K_Y,
    Z = sdl.K_Z,
    Escape = sdl.K_ESCAPE,
    LShift = sdl.K_LSHIFT,
    RShift = sdl.K_RSHIFT,
    @"?" = sdl.K_QUESTION,
    Tab = sdl.K_TAB,

    pub fn isShift(self: @This()) bool {
        return self == .LShift or self == .RShift;
    }
};
