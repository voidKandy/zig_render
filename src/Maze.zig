const std = @import("std");
const log = std.log.scoped(.Maze);

pub const CellState = enum {
    active,
    finished,
};

pub const CellRegion = enum {
    none,
    a,
    b,
};

pub const CellWalls = packed struct {
    north: bool = false,
    south: bool = false,
    east: bool = false,
    west: bool = false,
};

pub const Cell = struct {
    region: CellRegion = .none,
    walls: CellWalls = .{},
    region_mark: u8 = 0,
};
pub const CellIndex = struct { row: u32, col: u32 };

// A region is just a slice of the coordinate array
const Region = struct {
    min: usize,
    max: usize,
};

const Directions = enum {
    east,
    west,
    north,
    south,

    fn getValues(d: @This()) [2]i32 {
        return switch (d) {
            .east => .{ 0, 1 },
            .west => .{ 0, -1 },
            .north => .{ -1, 0 },
            .south => .{ 1, 0 },
        };
    }
};

width: u32,
height: u32,
cells: []Cell,
// flat array of all cell coordinates, partitioned as splits happen
coords: []CellIndex,

/// minimum number of cells in a region before splitting
/// should be moved to some builder struct
pub fn init(a: std.mem.Allocator, width: u32, height: u32) std.mem.Allocator.Error!@This() {
    const count = width * height;
    const cells = try a.alloc(Cell, count);
    @memset(cells, .{});

    const coords = try a.alloc(CellIndex, count);
    for (0..height) |row| {
        for (0..width) |col| {
            coords[row * width + col] = .{
                .row = @intCast(row),
                .col = @intCast(col),
            };
        }
    }

    return .{
        .width = width,
        .height = height,
        .cells = cells,
        .coords = coords,
    };
}

pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
    a.free(self.coords);
    a.free(self.cells);
}

fn cellAt(self: *@This(), row: u32, col: u32) *Cell {
    return &self.cells[row * self.width + col];
}

fn swapCoords(self: *@This(), i: usize, j: usize) void {
    const tmp = self.coords[i];
    self.coords[i] = self.coords[j];
    self.coords[j] = tmp;
}

pub fn initHallwaySquare(
    a: std.mem.Allocator,
    hw: u32,
) std.mem.Allocator.Error!Maze {
    var self = try Maze.init(a, hw, hw);
    var midpoint = hw / 2;
    midpoint -= if (hw % 2 == 0) 1 else 0;
    for (0..hw) |row| {
        const cell = self.cellAt(@intCast(row), midpoint);
        // in order to remain consistent with the way mazes are generated
        const cell_left = self.cellAt(@intCast(row), midpoint - 1);
        const cell_right = self.cellAt(@intCast(row), midpoint + 1);
        cell_left.walls.east = true;
        cell_right.walls.west = true;

        cell.walls.west = true;
        cell.walls.east = true;
        if (row == 0) cell.walls.north = true;
        if (row == hw) cell.walls.south = true;
    }

    return self;
}

pub const GenerationContext = struct {
    threshold: usize,
    seed: u64,
    rng: std.Random.DefaultPrng,
    stack: std.ArrayList(Region),
    current_mark: u8 = 0,

    pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
        self.stack.deinit(a);
    }

    fn rand(self: *@This(), min: usize, max: usize) usize {
        return min + self.rng.random().uintLessThan(usize, max - min);
    }
};

pub fn initGenerationContext(self: Maze, a: std.mem.Allocator, threshold: usize, seed: u64) std.mem.Allocator.Error!GenerationContext {
    var stack = try std.ArrayList(Region).initCapacity(a, self.cells.len);
    try stack.append(a, .{ .min = 0, .max = self.cells.len });
    return .{
        .threshold = threshold,
        .seed = seed,
        .rng = std.Random.DefaultPrng.init(seed),
        .stack = stack,
    };
}
/// Run one full split of the top region on the stack.
/// Returns true if more work remains.
pub fn step(self: *@This(), ctx: *GenerationContext) bool {
    ctx.current_mark +%= 1;
    if (ctx.stack.items.len == 0)
        return false;

    const region = ctx.stack.pop() orelse @panic("stack is empty?");
    const size = region.max - region.min;
    for (self.coords[region.min..region.max]) |idx|
        self.cellAt(idx.row, idx.col).region = .none;
    if (size < ctx.threshold) {
        for (self.coords[region.min..region.max]) |idx| {
            for (std.meta.tags(Directions)) |d| {
                const vals = d.getValues();
                const nr = @as(i32, @intCast(idx.row)) + vals[0];
                const nc = @as(i32, @intCast(idx.col)) + vals[1];
                if (nr < 0 or nc < 0 or
                    nr >= @as(i32, @intCast(self.height)) or
                    nc >= @as(i32, @intCast(self.width))) continue;

                const nidx = CellIndex{ .row = @intCast(nr), .col = @intCast(nc) };
                const neighbor = self.cellAt(nidx.row, nidx.col);
                // only clear walls toward cells in the same leaf region
                if (neighbor.region_mark != ctx.current_mark) continue;

                const from = self.cellAt(idx.row, idx.col);
                switch (d) {
                    .north => {
                        from.walls.north = false;
                        neighbor.walls.south = false;
                    },
                    .south => {
                        from.walls.south = false;
                        neighbor.walls.north = false;
                    },
                    .east => {
                        from.walls.east = false;
                        neighbor.walls.west = false;
                    },
                    .west => {
                        from.walls.west = false;
                        neighbor.walls.east = false;
                    },
                }
            }
        }
        return true;
    }

    // --- PLANT: pick two seeds ---
    // swap seed A to front
    const si_a = ctx.rand(region.min, region.max);
    self.swapCoords(region.min, si_a);
    const seed_a = self.coords[region.min];

    // swap seed B to min+1
    const si_b = ctx.rand(region.min + 1, region.max);
    self.swapCoords(region.min + 1, si_b);
    const seed_b = self.coords[region.min + 1];

    self.cellAt(seed_a.row, seed_a.col).region = .a;
    self.cellAt(seed_b.row, seed_b.col).region = .b;
    self.cellAt(seed_a.row, seed_a.col).region_mark = ctx.current_mark;
    self.cellAt(seed_b.row, seed_b.col).region_mark = ctx.current_mark;

    // --- GROW: flood fill from both seeds ---
    // use a simple frontier — reuse a fixed buffer via the stack allocator
    var frontier_buf: [4096]CellIndex = undefined;
    var frontier = std.ArrayListUnmanaged(CellIndex).initBuffer(&frontier_buf);

    frontier.appendAssumeCapacity(seed_a);
    frontier.appendAssumeCapacity(seed_b);

    while (frontier.items.len > 0) {
        // pick random cell from frontier
        const fi = ctx.rng.random().uintLessThan(usize, frontier.items.len);
        const cur_coords = frontier.swapRemove(fi);
        const cur_cell = self.cellAt(cur_coords.row, cur_coords.col);

        for (std.meta.tags(Directions)) |d| {
            const vals = d.getValues();
            const nr = @as(i32, @intCast(cur_coords.row)) + vals[0];
            const nc = @as(i32, @intCast(cur_coords.col)) + vals[1];
            if (nr < 0 or nc < 0 or
                nr >= @as(i32, @intCast(self.height)) or
                nc >= @as(i32, @intCast(self.width)))
                continue;

            const nidx = CellIndex{
                .row = @intCast(nr),
                .col = @intCast(nc),
            };

            const neighbor = self.cellAt(nidx.row, nidx.col);
            if (
            // neighbor.state != .active or
            neighbor.region != .none) continue;

            // claim for same subregion
            neighbor.region = cur_cell.region;
            neighbor.region_mark = ctx.current_mark;
            if (frontier.items.len < frontier_buf.len)
                frontier.appendAssumeCapacity(nidx);
        }
    }

    // partition the coords array into two contiguous subregions
    var lo = region.min;
    var hi = region.max - 1;
    while (lo < hi) {
        while (lo < hi and
            self.cellAt(self.coords[lo].row, self.coords[lo].col).region == .a)
            lo += 1;
        while (lo < hi and
            self.cellAt(self.coords[hi].row, self.coords[hi].col).region != .a)
            hi -= 1;

        if (lo < hi) {
            self.swapCoords(lo, hi);
            lo += 1;
            hi -= 1;
        }
    }

    var split = region.min;
    while (split < region.max and
        self.cellAt(self.coords[split].row, self.coords[split].col).region == .a)
        split += 1;

    const region_a = Region{ .min = region.min, .max = split };
    const region_b = Region{ .min = split, .max = region.max };

    // --- WALL: draw walls on boundary, leave one gap ---
    var gap_from: ?CellIndex = null;
    var gap_to: ?CellIndex = null;
    var gap_chosen = false;
    var boundary_count: usize = 0;

    for (self.coords[region_a.min..region_a.max]) |idx| {
        for (std.meta.tags(Directions)) |d| {
            const vals = d.getValues();
            const nr = @as(i32, @intCast(idx.row)) + vals[0];
            const nc = @as(i32, @intCast(idx.col)) + vals[1];

            if (nr < 0 or nc < 0 or
                nr >= @as(i32, @intCast(self.height)) or
                nc >= @as(i32, @intCast(self.width))) continue;

            const nidx = CellIndex{ .row = @intCast(nr), .col = @intCast(nc) };
            const neighbor = self.cellAt(nidx.row, nidx.col);
            if (neighbor.region == .a) continue; // same subregion
            if (neighbor.region_mark == ctx.current_mark and neighbor.region == .b) {
                boundary_count += 1;
                // reservoir sampling for the gap
                if (!gap_chosen or ctx.rng.random().uintLessThan(usize, boundary_count) == 0) {
                    gap_from = idx;
                    gap_to = nidx;
                    gap_chosen = true;
                }
            }
        }
    }

    // now draw all walls except the gap
    for (self.coords[region_a.min..region_a.max]) |idx| {
        for (std.meta.tags(Directions)) |d| {
            const vals = d.getValues();
            const nr = @as(i32, @intCast(idx.row)) + vals[0];
            const nc = @as(i32, @intCast(idx.col)) + vals[1];
            if (nr < 0 or nc < 0 or
                nr >= @as(i32, @intCast(self.height)) or
                nc >= @as(i32, @intCast(self.width))) continue;

            const nidx = CellIndex{ .row = @intCast(nr), .col = @intCast(nc) };
            const neighbor = self.cellAt(nidx.row, nidx.col);
            if (neighbor.region_mark != ctx.current_mark or neighbor.region != .b) continue;

            const gf = gap_from.?;
            const gt = gap_to.?;
            if (gf.row == idx.row and gf.col == idx.col and
                gt.row == nidx.row and gt.col == nidx.col) continue;

            // add wall
            const from = self.cellAt(idx.row, idx.col);
            switch (d) {
                .north => {
                    from.walls.north = true;
                    neighbor.walls.south = true;
                },
                .south => {
                    from.walls.south = true;
                    neighbor.walls.north = true;
                },
                .east => {
                    from.walls.east = true;
                    neighbor.walls.west = true;
                },
                .west => {
                    from.walls.west = true;
                    neighbor.walls.east = true;
                },
            }
        }
    }

    // push subregions if big enough
    if (region_a.max - region_a.min >= ctx.threshold)
        ctx.stack.appendAssumeCapacity(region_a);

    if (region_b.max - region_b.min >= ctx.threshold)
        ctx.stack.appendAssumeCapacity(region_b);

    return true;
}

const Maze = @This();
const print = std.debug.print;

test "maze seeded display" {
    const a = std.testing.allocator;
    var maze = try Maze.init(a, 20, 10);
    defer maze.deinit(a);
    const seed = 12345;
    var ctx = try maze.initGenerationContext(a, 16, seed);
    defer ctx.deinit(a);
    // run to completion
    while (maze.step(&ctx)) {}
    for (0..maze.height) |row| {
        for (0..maze.width) |col| {
            const cell = &maze.cells[row * maze.width + col];
            if (row == 0) cell.walls.north = true;
            if (row == maze.height - 1) cell.walls.south = true;
            if (col == 0) cell.walls.west = true;
            if (col == maze.width - 1) cell.walls.east = true;
        }
    }

    print(
        \\ SEEDED MAZE: {}
        \\
    , .{seed});
    // print top border
    print("+", .{});
    for (0..maze.width) |_| print("--+", .{});
    print("\n", .{});

    for (0..maze.height) |row| {
        // left border + cell row
        print("|", .{});
        for (0..maze.width) |col| {
            const cell = maze.cells[row * maze.width + col];
            // east wall
            if (cell.walls.east) {
                print("  |", .{});
            } else {
                print("   ", .{});
            }
        }
        print("\n", .{});

        // south walls row
        print("+", .{});
        for (0..maze.width) |col| {
            const cell = maze.cells[row * maze.width + col];
            if (cell.walls.south) {
                print("--+", .{});
            } else {
                print("  +", .{});
            }
        }
        print("\n", .{});
    }
}

test "maze hallway display" {
    const a = std.testing.allocator;
    var maze = try Maze.initHallwaySquare(a, 20);
    defer maze.deinit(a);
    for (0..maze.height) |row| {
        for (0..maze.width) |col| {
            const cell = &maze.cells[row * maze.width + col];
            if (row == 0) cell.walls.north = true;
            if (row == maze.height - 1) cell.walls.south = true;
            if (col == 0) cell.walls.west = true;
            if (col == maze.width - 1) cell.walls.east = true;
        }
    }
    print(
        \\ HALLWAY MAZE
        \\
    , .{});
    // print top border
    print("+", .{});
    for (0..maze.width) |_| print("--+", .{});
    print("\n", .{});

    for (0..maze.height) |row| {
        // left border + cell row
        print("|", .{});
        for (0..maze.width) |col| {
            const cell = maze.cells[row * maze.width + col];
            // east wall
            if (cell.walls.east) {
                print("  |", .{});
            } else {
                print("   ", .{});
            }
        }
        print("\n", .{});

        // south walls row
        print("+", .{});
        for (0..maze.width) |col| {
            const cell = maze.cells[row * maze.width + col];
            if (cell.walls.south) {
                print("--+", .{});
            } else {
                print("  +", .{});
            }
        }
        print("\n", .{});
    }
}
