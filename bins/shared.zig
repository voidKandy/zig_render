const std = @import("std");
const engine = @import("engine");

pub const systems = struct {
    pub const Camera = @import("systems/Camera.zig");
    pub const Debug = @import("systems/Debug.zig");
    pub const DrawBackground = @import("systems/DrawBackground.zig");
    pub const Maze = @import("systems/Maze.zig");
};
pub const SystemManager = engine.engine.systems.SystemManager(GameWorld, &[_]type{
    systems.Maze,
    systems.Camera,
    systems.DrawBackground,
    systems.Debug,
});

pub const GameWorld = engine.engine.world.GameWorldType(.{ .max_entities = 64, .Components = struct {
    camera: systems.Camera.Controller,
} });
