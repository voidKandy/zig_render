const std = @import("std");
const log = std.log.scoped(.mtl_loader);
const Allocator = std.mem.Allocator;

pub const Material = struct {
    name: []const u8,
    map_Kd: ?[]const u8,
    Kd: ?[3]f32 = null,
};

const ParseContext = struct {
    allocator: Allocator,
    temp_alloc: Allocator,
    line: u32,
    line_content: []const u8,
    filename: []const u8,

    materials: std.ArrayList(Material),

    // current material being parsed
    current_name: ?[]const u8 = null,
    current_map_Kd: ?[]const u8 = null,
    current_Kd: ?[3]f32 = null,

    fn init(allocator: Allocator, temp_alloc: Allocator, filename: []const u8) Allocator.Error!ParseContext {
        return .{
            .allocator = allocator,
            .temp_alloc = temp_alloc,
            .line = 0,
            .line_content = "",
            .filename = filename,
            .materials = try std.ArrayList(Material).initCapacity(allocator, 64),
        };
    }

    fn deinit(self: *@This()) void {
        self.materials.deinit(self.allocator);
    }
};

pub const MtlFile = struct {
    name: []u8,
    allocator: Allocator,
    materials: []Material,

    pub fn deinit(self: *MtlFile) void {
        for (self.materials) |mat| {
            self.allocator.free(mat.name);
            if (mat.map_Kd) |m| self.allocator.free(m);
        }
        self.allocator.free(self.materials);
        self.allocator.free(self.name);
    }

    pub fn find(self: *MtlFile, name: []const u8) ?Material {
        for (self.materials) |mat| {
            if (std.mem.eql(u8, mat.name, name)) return mat;
        }
        return null;
    }
};

const ParseError = error{
    UnexpectedEndOfFile,
    InvalidToken,
    MissingMaterialName,
};

pub fn parseFile(a: Allocator, io: std.Io, filepath: []const u8) !MtlFile {
    const file = try std.Io.Dir.cwd().openFile(io, filepath, .{ .mode = .read_only });
    defer file.close(io);

    const last_slash_idx = if (std.mem.indexOfScalar(u8, filepath, '/')) |i| i + 1 else 0;
    const name = try a.dupe(u8, filepath[last_slash_idx..]);

    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();

    var ctx = try ParseContext.init(a, arena_state.allocator(), filepath);

    var file_reader = file.reader(io, &.{});
    const file_content = try file_reader.interface.allocRemaining(a, .limited(1024));

    try parseContent(&ctx, file_content);

    // flush the last material
    try flushMaterial(&ctx);

    return MtlFile{
        .name = name,
        .allocator = a,
        .materials = try ctx.materials.toOwnedSlice(a),
    };
}

fn parseString(a: Allocator, content: []const u8, filename: []const u8) (error{InvalidCharacter} || Allocator.Error)!MtlFile {
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();

    var ctx = try ParseContext.init(a, arena_state.allocator(), filename);

    const name = try a.dupe(u8, filename);

    try parseContent(&ctx, content);
    try flushMaterial(&ctx);

    return MtlFile{
        .name = name,
        .allocator = a,
        .materials = try ctx.materials.toOwnedSlice(a),
    };
}

fn flushMaterial(ctx: *ParseContext) Allocator.Error!void {
    const name = ctx.current_name orelse return; // nothing to flush

    try ctx.materials.append(ctx.allocator, .{
        .name = try ctx.allocator.dupe(u8, name),
        .map_Kd = if (ctx.current_map_Kd) |m| try ctx.allocator.dupe(u8, m) else null,
        .Kd = if (ctx.current_Kd) |k| k else null,
    });

    ctx.current_name = null;
    ctx.current_map_Kd = null;
    ctx.current_Kd = null;
}

fn parseContent(ctx: *ParseContext, content: []const u8) (Allocator.Error || std.fmt.ParseFloatError)!void {
    var lines = std.mem.tokenizeAny(u8, content, "\n\r");
    while (lines.next()) |raw_line| {
        ctx.line += 1;
        ctx.line_content = raw_line;
        const line = std.mem.trim(u8, raw_line, " \t\r");

        if (line.len == 0 or line[0] == '#') continue;

        if (std.mem.startsWith(u8, line, "newmtl ")) {
            // flush previous material before starting a new one
            try flushMaterial(ctx);
            ctx.current_name = std.mem.trim(u8, line["newmtl ".len..], " \t");
        } else if (std.mem.startsWith(u8, line, "map_Kd ")) {
            ctx.current_map_Kd = std.mem.trim(u8, line["map_Kd ".len..], " \t");
        } else if (std.mem.startsWith(u8, line, "Kd ")) {
            const rest = std.mem.trim(u8, line["Kd ".len..], " \t");
            var it = std.mem.tokenizeScalar(u8, rest, ' ');
            const r = try std.fmt.parseFloat(f32, it.next() orelse "0");
            const g = try std.fmt.parseFloat(f32, it.next() orelse "0");
            const b = try std.fmt.parseFloat(f32, it.next() orelse "0");
            ctx.current_Kd = .{ r, g, b };
        }

        // everything else is intentionally ignored
    }
}

inline fn logErr(ctx: *ParseContext, comptime msg: []const u8, args: anytype) void {
    log.err("{s}: {}: " ++ msg ++ "\nLine content: {s}", .{ ctx.filename, ctx.line } ++ args ++ .{ctx.line_content});
}

inline fn logWarn(ctx: *ParseContext, comptime msg: []const u8, args: anytype) void {
    log.warn("{s}: {}: " ++ msg, .{ ctx.filename, ctx.line } ++ args);
}

test "mtl parser: basic newmtl and map_Kd" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const raw =
        \\# Basic test material
        \\newmtl my_material
        \\map_Kd diffuse.png
        \\
        \\newmtl second_material
        \\map_Kd other.png
    ;

    var result = try parseString(allocator, raw, "test.mtl");
    defer result.deinit();

    try testing.expectEqual(@as(usize, 2), result.materials.len);

    try testing.expectEqualStrings("my_material", result.materials[0].name);
    try testing.expectEqualStrings("diffuse.png", result.materials[0].map_Kd.?);

    try testing.expectEqualStrings("second_material", result.materials[1].name);
    try testing.expectEqualStrings("other.png", result.materials[1].map_Kd.?);
}

test "mtl parser: material with no map_Kd defaults to empty string" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const raw =
        \\newmtl bare_material
    ;

    var result = try parseString(allocator, raw, "test.mtl");
    defer result.deinit();

    try testing.expectEqual(@as(usize, 1), result.materials.len);
    try testing.expectEqualStrings("bare_material", result.materials[0].name);
    try testing.expectEqual(null, result.materials[0].map_Kd);
}
