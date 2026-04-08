const std = @import("std");
const log = std.log.scoped(.mtl_loader);
const Allocator = std.mem.Allocator;

pub const Material = struct {
    name: []const u8,
    map_Kd: []const u8,
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
    allocator: Allocator,
    materials: []Material,

    pub fn deinit(self: *MtlFile) void {
        for (self.materials) |mat| {
            self.allocator.free(mat.name);
            self.allocator.free(mat.map_Kd);
        }
        self.allocator.free(self.materials);
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

pub fn parseFile(a: Allocator, filepath: []const u8) !MtlFile {
    const file = try std.fs.cwd().openFile(filepath, .{ .mode = .read_only });
    defer file.close();

    const file_size = try file.getEndPos();

    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();

    var ctx = try ParseContext.init(a, arena_state.allocator(), filepath);

    const file_content = try file.readToEndAlloc(ctx.temp_alloc, file_size);

    try parseContent(&ctx, file_content);

    // flush the last material
    try flushMaterial(&ctx);

    return MtlFile{
        .allocator = a,
        .materials = try ctx.materials.toOwnedSlice(a),
    };
}

pub fn parseString(a: Allocator, content: []const u8, filename: []const u8) Allocator.Error!MtlFile {
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();

    var ctx = try ParseContext.init(a, arena_state.allocator(), filename);
    try parseContent(&ctx, content);
    try flushMaterial(&ctx);

    return MtlFile{
        .allocator = a,
        .materials = try ctx.materials.toOwnedSlice(a),
    };
}

fn flushMaterial(ctx: *ParseContext) Allocator.Error!void {
    const name = ctx.current_name orelse return; // nothing to flush
    const map_Kd = ctx.current_map_Kd orelse "";

    try ctx.materials.append(ctx.allocator, .{
        .name = try ctx.allocator.dupe(u8, name),
        .map_Kd = try ctx.allocator.dupe(u8, map_Kd),
    });

    ctx.current_name = null;
    ctx.current_map_Kd = null;
}

fn parseContent(ctx: *ParseContext, content: []const u8) Allocator.Error!void {
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
    try testing.expectEqualStrings("diffuse.png", result.materials[0].map_Kd);

    try testing.expectEqualStrings("second_material", result.materials[1].name);
    try testing.expectEqualStrings("other.png", result.materials[1].map_Kd);
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
    try testing.expectEqualStrings("", result.materials[0].map_Kd);
}
