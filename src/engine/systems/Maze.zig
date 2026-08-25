const std = @import("std");
const core = @import("../../root.zig");
const log = std.log.scoped(.MazeSystem);
const imgui = core.clibs.imgui;

maze: core.lib.Maze,
maze_gpu_cells: []GPUMazeCell,
push_constants: PushConstants,
maze_update: bool = false,
needs_gpu_sync: bool = true,

pub const PushConstants = extern struct {
    width: u32,
    height: u32,
    pixels_per_cell: u32,
    /// size of maze mesh cells in world scale
    cell_size: f32,
    maze_origin: core.lib.math.Vec3,
    seed: u32,
    threshold: usize,
};

pub const GPUMazeCell = extern struct {
    walls: u32,

    /// mutates a pre-allocated array of gpucells
    fn convertCells(arr: []core.lib.Maze.Cell, self_arr: *[]@This()) void {
        @memset(self_arr.*, .{
            .walls = 0,
        });
        for (arr, 0..) |item, i| {
            self_arr.*[i].walls =
                (@as(u32, @intFromBool(item.walls.north)) << 0) |
                (@as(u32, @intFromBool(item.walls.south)) << 1) |
                (@as(u32, @intFromBool(item.walls.east)) << 2) |
                (@as(u32, @intFromBool(item.walls.west)) << 3);
        }
    }

    fn arrayFromCellArray(a: std.mem.Allocator, arr: []core.lib.Maze.Cell) std.mem.Allocator.Error![]@This() {
        var all = try a.alloc(GPUMazeCell, arr.len);
        for (arr, 0..) |item, i| {
            all[i].walls =
                (@as(u32, @intFromBool(item.walls.north)) << 0) |
                (@as(u32, @intFromBool(item.walls.south)) << 1) |
                (@as(u32, @intFromBool(item.walls.east)) << 2) |
                (@as(u32, @intFromBool(item.walls.west)) << 3);
        }
        return all;
    }
};

pub fn init(a: std.mem.Allocator, push_constants: PushConstants) std.mem.Allocator.Error!@This() {
    var maze = try core.lib.Maze.init(a, push_constants.width, push_constants.height);
    maze.generate(push_constants.threshold, push_constants.seed);
    const cells =
        try GPUMazeCell.arrayFromCellArray(a, maze.cells);

    return .{
        .maze = maze,
        .maze_gpu_cells = cells,
        .push_constants = push_constants,
    };
}

pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
    self.maze.deinit(a);
    a.free(self.maze_gpu_cells);
}

pub fn trySyncResources(self: *@This(), alloc_resources: core.resources.Manager.AllocatedData) void {
    if (self.needs_gpu_sync) {
        const aligned_maze: [*]GPUMazeCell = @ptrCast(@alignCast(alloc_resources.all_mapped_buffers.get("maze").?.mapped));
        @memcpy(aligned_maze, self.maze_gpu_cells);
        self.needs_gpu_sync = false;
    }
}

pub fn update(
    self: *@This(),
) void {
    if (self.maze_update) {
        for (self.maze.cells) |*c|
            c.walls = .{};

        self.maze.generate(self.maze.threshold.?, self.maze.seed.?);

        GPUMazeCell.convertCells(self.maze.cells, &self.maze_gpu_cells);

        self.maze_update = false;
        self.needs_gpu_sync = true;
    }
}

pub fn drawImgui(
    self: *@This(),
    ui_set: core.clibs.vk.DescriptorSet,
) void {
    var open = true;
    const shown = imgui.Begin("Maze", &open, core.clibs.imgui.WINDOW_ALWAYS_AUTO_RESIZE);
    var seed: c_int = @intCast(self.maze.seed.?);
    if (imgui.InputInt("seed", &seed)) {
        self.maze.seed = @as(u64, @intCast(seed));
        self.maze_update = true;
    }
    defer imgui.End();
    if (!shown) return;
    imgui.Image(ui_set, imgui.ImVec2{ .x = 400, .y = 400 });
}
