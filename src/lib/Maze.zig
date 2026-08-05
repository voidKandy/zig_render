const std = @import("std");
const log = std.log.scoped(.Maze);

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

    fn vector(d: @This()) [2]i32 {
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
/// flat array of all cell coordinates, partitioned as splits happen
coords: []CellIndex,
threshold: ?usize = null,
seed: ?u64 = null,

// TEMP
open_cells: []const CellIndex = &[_]CellIndex{
    .{
        .col = 0,
        .row = 0,
    },
},

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
        const row_cell = self.cellAt(@intCast(row), midpoint);
        // in order to remain consistent with the way mazes are generated
        const cell_left = self.cellAt(@intCast(row), midpoint - 1);
        const cell_right = self.cellAt(@intCast(row), midpoint + 1);
        cell_left.walls.east = true;
        cell_right.walls.west = true;

        row_cell.walls.west = true;
        row_cell.walls.east = true;
        if (row == 0) row_cell.walls.north = true;
        if (row == hw) row_cell.walls.south = true;

        for (0..hw) |col| {
            const col_cell = &self.cells[row * self.width + col];
            if (row == 0) col_cell.walls.north = true;
            if (row == self.height - 1) col_cell.walls.south = true;
            if (col == 0) col_cell.walls.west = true;
            if (col == self.width - 1) col_cell.walls.east = true;
        }
    }

    return self;
}

pub fn generate(self: *@This(), a: std.mem.Allocator, threshold: usize, seed: u64) void {
    var ctx = self.createGenerationContext(a, threshold, seed) catch @panic("failed to init generation context");
    defer ctx.deinit(a);
    while (ctx.step(self)) {}

    for (0..self.height) |row| {
        for (0..self.width) |col| {
            if (std.meta.eql(self.open_cells[0], CellIndex{
                .col = @as(u32, @intCast(col)),
                .row = @as(u32, @intCast(row)),
            })) {
                continue;
            }
            const cell = &self.cells[row * self.width + col];
            if (row == 0) cell.walls.north = true;
            if (row == self.height - 1) cell.walls.south = true;
            if (col == 0) cell.walls.west = true;
            if (col == self.width - 1) cell.walls.east = true;
        }
    }
    self.threshold = threshold;
    self.seed = seed;
}

const mesh = @import("../root.zig").lib.mesh;
const math = @import("../root.zig").lib.math;
pub const MeshOptions = struct {
    cell_size: f32,
    wall_height: f32,
    wall_thickness: math.Vec2 = .{
        .x = 0.5,
        .y = 0.5,
    },
    margin: math.Vec3 = .ZERO,
    origin: math.Vec3 = .ZERO,

    fn appendQuad(
        a: std.mem.Allocator,
        vertices: *std.ArrayList(mesh.Vertex3D),
        indices: *std.ArrayList(u32),
        p0: [3]f32,
        p1: [3]f32,
        p2: [3]f32,
        p3: [3]f32,
        normal: [3]f32,
    ) !void {
        const base: u32 = @intCast(vertices.items.len);
        const norm = math.Vec4.make(normal[0], normal[1], normal[2], 0);
        try vertices.appendSlice(a, &.{
            .{
                .position = math.Vec4.make(p0[0], p0[1], p0[2], 1),
                .normal = norm,
                .color = math.Vec4.ZERO,
                .uv = math.Vec2.make(0, 0),
            },
            .{
                .position = math.Vec4.make(p1[0], p1[1], p1[2], 1),
                .normal = norm,
                .color = math.Vec4.ZERO,
                .uv = math.Vec2.make(1, 0),
            },
            .{
                .position = math.Vec4.make(p2[0], p2[1], p2[2], 1),
                .normal = norm,
                .color = math.Vec4.ZERO,
                .uv = math.Vec2.make(1, 1),
            },
            .{
                .position = math.Vec4.make(p3[0], p3[1], p3[2], 1),
                .normal = norm,
                .color = math.Vec4.ZERO,
                .uv = math.Vec2.make(0, 1),
            },
        });
        try indices.appendSlice(a, &.{ base, base + 1, base + 2, base, base + 2, base + 3 });
    }

    fn point(
        self: @This(),
        x: f32,
        y: f32,
        z: f32,
        row: f32,
        col: f32,
    ) [3]f32 {
        return .{
            x + self.margin.x * col,
            y + self.margin.y * row,
            z - self.margin.z,
        };
    }

    fn appendBox(
        a: std.mem.Allocator,
        vertices: *std.ArrayList(mesh.Vertex3D),
        indices: *std.ArrayList(u32),
        min: [3]f32,
        max: [3]f32,
    ) !void {
        // -y
        try appendQuad(
            a,
            vertices,
            indices,
            .{ min[0], min[1], min[2] },
            .{ max[0], min[1], min[2] },
            .{ max[0], min[1], max[2] },
            .{ min[0], min[1], max[2] },
            .{ 0, -1, 0 },
        );
        // +y
        try appendQuad(
            a,
            vertices,
            indices,
            .{ max[0], max[1], min[2] },
            .{ min[0], max[1], min[2] },
            .{ min[0], max[1], max[2] },
            .{ max[0], max[1], max[2] },
            .{ 0, 1, 0 },
        );
        // -x
        try appendQuad(
            a,
            vertices,
            indices,
            .{ min[0], max[1], min[2] },
            .{ min[0], min[1], min[2] },
            .{ min[0], min[1], max[2] },
            .{ min[0], max[1], max[2] },
            .{ -1, 0, 0 },
        );
        // +x
        try appendQuad(
            a,
            vertices,
            indices,
            .{ max[0], min[1], min[2] },
            .{ max[0], max[1], min[2] },
            .{ max[0], max[1], max[2] },
            .{ max[0], min[1], max[2] },
            .{ 1, 0, 0 },
        );
        // top
        try appendQuad(
            a,
            vertices,
            indices,
            .{ min[0], min[1], max[2] },
            .{ max[0], min[1], max[2] },
            .{ max[0], max[1], max[2] },
            .{ min[0], max[1], max[2] },
            .{ 0, 0, 1 },
        );
        // bottom omitted — it sits on the floor, no need to render it
    }

    pub fn createMesh(
        self: @This(),
        a: std.mem.Allocator,
        maze: Maze,
    ) !mesh.Mesh3D {
        var vertices = try std.ArrayList(mesh.Vertex3D).initCapacity(a, 256);
        var indices = try std.ArrayList(u32).initCapacity(a, 256);
        errdefer vertices.deinit(a);

        const th = self.wall_thickness;
        errdefer indices.deinit(a);

        for (maze.cells, 0..) |cell, i| {
            const row: f32 = @floatFromInt(i / maze.width);
            const col: f32 = @floatFromInt(i % maze.width);
            const x0 = self.origin.x + col * self.cell_size;
            const x1 = x0 + self.cell_size;
            const y0 = self.origin.y + row * self.cell_size;
            const y1 = y0 + self.cell_size;

            // floor
            try appendQuad(
                a,
                &vertices,
                &indices,
                .{ x0, y0, 0 },
                .{ x1, y0, 0 },
                .{ x1, y1, 0 },
                .{ x0, y1, 0 },
                .{ 0, 0, 1 },
            );

            if (cell.walls.north) try appendBox(
                a,
                &vertices,
                &indices,
                .{ x0 - th.x / 2, y0 - th.y / 2, 0 },
                .{ x1 + th.x / 2, y0 + th.y / 2, self.wall_height },
            );

            if (cell.walls.south) try appendBox(
                a,
                &vertices,
                &indices,
                .{ x0 - th.x / 2, y1 - th.y / 2, 0 },
                .{ x1 + th.x / 2, y1 + th.y / 2, self.wall_height },
            );

            if (cell.walls.east) try appendBox(
                a,
                &vertices,
                &indices,
                .{ x1 - th.x / 2, y0 - th.y / 2, 0 },
                .{ x1 + th.x / 2, y1 + th.y / 2, self.wall_height },
            );

            if (cell.walls.west) try appendBox(
                a,
                &vertices,
                &indices,
                .{ x0 - th.x / 2, y0 - th.y / 2, 0 },
                .{ x0 + th.x / 2, y1 + th.y / 2, self.wall_height },
            );
        }

        return .{
            .vertices = try vertices.toOwnedSlice(a),
            .indices = try indices.toOwnedSlice(a),
        };
    }
};

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

    /// Run one full split of the top region on the stack.
    /// Returns true if more work remains.
    pub fn step(self: *@This(), maze: *Maze) bool {
        self.current_mark +%= 1;
        if (self.stack.items.len == 0)
            return false;

        const region = self.stack.pop() orelse @panic("stack is empty?");
        const size = region.max - region.min;
        for (maze.coords[region.min..region.max]) |idx|
            maze.cellAt(idx.row, idx.col).region = .none;

        if (size < self.threshold) {
            for (maze.coords[region.min..region.max]) |idx| {
                for (std.meta.tags(Directions)) |d| {
                    const vec = d.vector();
                    const nr = @as(i32, @intCast(idx.row)) + vec[0];
                    const nc = @as(i32, @intCast(idx.col)) + vec[1];
                    if (nr < 0 or
                        nc < 0 or
                        nr >= @as(i32, @intCast(maze.height)) or
                        nc >= @as(i32, @intCast(maze.width))) continue;

                    const nidx = CellIndex{ .row = @intCast(nr), .col = @intCast(nc) };
                    const neighbor = maze.cellAt(nidx.row, nidx.col);
                    // only clear walls toward cells in the same leaf region
                    if (neighbor.region_mark != self.current_mark) continue;

                    const from = maze.cellAt(idx.row, idx.col);
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
        const si_a = self.rand(region.min, region.max);
        maze.swapCoords(region.min, si_a);
        const seed_a = maze.coords[region.min];

        // swap seed B to min+1
        const si_b = self.rand(region.min + 1, region.max);
        maze.swapCoords(region.min + 1, si_b);
        const seed_b = maze.coords[region.min + 1];

        maze.cellAt(seed_a.row, seed_a.col).region = .a;
        maze.cellAt(seed_b.row, seed_b.col).region = .b;
        maze.cellAt(seed_a.row, seed_a.col).region_mark = self.current_mark;
        maze.cellAt(seed_b.row, seed_b.col).region_mark = self.current_mark;

        // --- GROW: flood fill from both seeds ---
        // use a simple frontier — reuse a fixed buffer via the stack allocator
        var frontier_buf: [4096]CellIndex = undefined;
        var frontier = std.ArrayListUnmanaged(CellIndex).initBuffer(&frontier_buf);

        frontier.appendAssumeCapacity(seed_a);
        frontier.appendAssumeCapacity(seed_b);

        while (frontier.items.len > 0) {
            // pick random cell from frontier
            const fi = self.rng.random().uintLessThan(usize, frontier.items.len);
            const cur_coords = frontier.swapRemove(fi);
            const cur_cell = maze.cellAt(cur_coords.row, cur_coords.col);

            for (std.meta.tags(Directions)) |d| {
                const vec = d.vector();
                const nr = @as(i32, @intCast(cur_coords.row)) + vec[0];
                const nc = @as(i32, @intCast(cur_coords.col)) + vec[1];
                if (nr < 0 or nc < 0 or
                    nr >= @as(i32, @intCast(maze.height)) or
                    nc >= @as(i32, @intCast(maze.width)))
                    continue;

                const nidx = CellIndex{
                    .row = @intCast(nr),
                    .col = @intCast(nc),
                };

                const neighbor = maze.cellAt(nidx.row, nidx.col);
                if (
                // neighbor.state != .active or
                neighbor.region != .none) continue;

                // claim for same subregion
                neighbor.region = cur_cell.region;
                neighbor.region_mark = self.current_mark;
                if (frontier.items.len < frontier_buf.len)
                    frontier.appendAssumeCapacity(nidx);
            }
        }

        // partition the coords array into two contiguous subregions
        var lo = region.min;
        var hi = region.max - 1;
        while (lo < hi) {
            while (lo < hi and
                maze.cellAt(maze.coords[lo].row, maze.coords[lo].col).region == .a)
                lo += 1;
            while (lo < hi and
                maze.cellAt(maze.coords[hi].row, maze.coords[hi].col).region != .a)
                hi -= 1;

            if (lo < hi) {
                maze.swapCoords(lo, hi);
                lo += 1;
                hi -= 1;
            }
        }

        var split = region.min;
        while (split < region.max and
            maze.cellAt(maze.coords[split].row, maze.coords[split].col).region == .a)
            split += 1;

        const region_a = Region{ .min = region.min, .max = split };
        const region_b = Region{ .min = split, .max = region.max };

        // --- WALL: create walls on boundary, leave one gap ---
        var gap_from: ?CellIndex = null;
        var gap_to: ?CellIndex = null;
        var gap_chosen = false;
        var boundary_count: usize = 0;

        for (maze.coords[region_a.min..region_a.max]) |idx| {
            for (std.meta.tags(Directions)) |d| {
                const vec = d.vector();
                const nr = @as(i32, @intCast(idx.row)) + vec[0];
                const nc = @as(i32, @intCast(idx.col)) + vec[1];

                if (nr < 0 or nc < 0 or
                    nr >= @as(i32, @intCast(maze.height)) or
                    nc >= @as(i32, @intCast(maze.width))) continue;

                const nidx = CellIndex{ .row = @intCast(nr), .col = @intCast(nc) };
                const neighbor = maze.cellAt(nidx.row, nidx.col);
                if (neighbor.region == .a) continue; // same subregion
                if (neighbor.region_mark == self.current_mark and neighbor.region == .b) {
                    boundary_count += 1;
                    // reservoir sampling for the gap
                    if (!gap_chosen or self.rng.random().uintLessThan(usize, boundary_count) == 0) {
                        gap_from = idx;
                        gap_to = nidx;
                        gap_chosen = true;
                    }
                }
            }
        }

        // now draw all walls except the gap
        for (maze.coords[region_a.min..region_a.max]) |idx| {
            for (std.meta.tags(Directions)) |d| {
                const vec = d.vector();
                const nr = @as(i32, @intCast(idx.row)) + vec[0];
                const nc = @as(i32, @intCast(idx.col)) + vec[1];
                if (nr < 0 or nc < 0 or
                    nr >= @as(i32, @intCast(maze.height)) or
                    nc >= @as(i32, @intCast(maze.width))) continue;

                const nidx = CellIndex{ .row = @intCast(nr), .col = @intCast(nc) };
                const neighbor = maze.cellAt(nidx.row, nidx.col);
                if (neighbor.region_mark != self.current_mark or neighbor.region != .b) continue;

                const gf = gap_from.?;
                const gt = gap_to.?;
                if (gf.row == idx.row and gf.col == idx.col and
                    gt.row == nidx.row and gt.col == nidx.col) continue;

                // add wall
                const from = maze.cellAt(idx.row, idx.col);
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
        if (region_a.max - region_a.min >= self.threshold)
            self.stack.appendAssumeCapacity(region_a);

        if (region_b.max - region_b.min >= self.threshold)
            self.stack.appendAssumeCapacity(region_b);

        return true;
    }
};

pub fn createGenerationContext(self: Maze, a: std.mem.Allocator, threshold: usize, seed: u64) std.mem.Allocator.Error!GenerationContext {
    var stack = try std.ArrayList(Region).initCapacity(a, self.cells.len);
    try stack.append(a, .{ .min = 0, .max = self.cells.len });
    return .{
        .threshold = threshold,
        .seed = seed,
        .rng = std.Random.DefaultPrng.init(seed),
        .stack = stack,
    };
}

const Maze = @This();
const print = std.debug.print;

test "maze seeded display" {
    const a = std.testing.allocator;
    var maze = try Maze.init(a, 20, 10);
    defer maze.deinit(a);
    const seed = 12345;

    maze.generate(a, 16, seed);

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
