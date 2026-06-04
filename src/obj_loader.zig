// Copyright (c) Samuele Panzeri
// SPDX-License-Identifier: MIT OR Apache-2.0
//
// This file is made specifically for this zig implementation of the vk guide.
// As such, you should be able to use it for another project.
// I have tried to write it such as to not have dependencies on the rest of the project.
//
// NOTE: Keep in mind this is not yet a fully compliant obj loader. Some work
// is needed to add support for at least materials.
// Consider it more of a starting point than a finished product.
// Also, keep in mind this is simply a parser for objs. It does not triangulate
// the faces, nor does it try to optimize the data or generate an index buffer.
//
// This code was originally part of: https://github.com/spanzeri/vkguide-zig
// For simple use and triangulation, check src/mesh.zig in the same repo.
//
const std = @import("std");
const core = @import("root.zig");

const log = std.log.scoped(.obj_loader);

pub const Index = struct {
    vertex: u32,
    normal: u32,
    uv: u32,
};

pub const MaterialInfo = struct {
    material_name: []u8,
    range: core.mesh.RangeDesc,
};

pub const Object = struct {
    name: []u8,
    material_name: []u8,
    face_vertices: []u32,
    indices: []Index,
    material_ranges: []MaterialInfo,

    pub fn deinit(self: *@This(), a: std.mem.Allocator) void {
        a.free(self.face_vertices);
        a.free(self.name);
        a.free(self.material_name);
        a.free(self.indices);
        for (self.material_ranges) |*r| a.free(r.material_name);
        a.free(self.material_ranges);
    }
};

pub fn readObjDirectory(a: std.mem.Allocator, dir_path: []const u8) ![]ObjFile {
    var dir = try std.fs.cwd().openDir(dir_path, .{ .iterate = true });
    var iter = try dir.walk(a);
    defer iter.deinit();
    var obj_files = try std.ArrayList(ObjFile).initCapacity(a, 3);

    while (try iter.next()) |entry| {
        const path = std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, entry.basename }) catch @panic("failed to alloc path");
        defer a.free(path);
        const obj = try parseFile(a, path);
        try obj_files.append(a, obj);
    }

    return try obj_files.toOwnedSlice(a);
}

// TODO
// remove ownership of allocator
pub const ObjFile = struct {
    allocator: std.mem.Allocator,
    material_library_name: []u8,

    objects: []Object,

    vertices: [][3]f32,
    normals: [][3]f32,
    uvs: [][2]f32,

    pub fn deinit(self: *@This()) void {
        self.allocator.free(self.material_library_name);
        self.allocator.free(self.vertices);
        self.allocator.free(self.normals);
        self.allocator.free(self.uvs);
        for (self.objects) |*object|
            object.deinit(self.allocator);

        self.allocator.free(self.objects);
    }
};

pub const ParseError = error{
    UnexpectedEndOfFile,
    InvalidToken,
    InvalidEntry,
    InvalidNumber,
    InvalidIndex,
};

const ParseContext = struct {
    temp_alloc: std.mem.Allocator,
    allocator: std.mem.Allocator,
    line: u32,
    line_content: []const u8,
    filename: []const u8,

    objects: std.ArrayList(Object) = .{},

    material_library_name: []const u8 = "",
    current_material_name: []const u8 = "",

    material_ranges: std.ArrayList(MaterialInfo) = .{},
    current_range_first_index: u32 = 0,

    object_name: []const u8 = "",
    vertices: std.ArrayList([3]f32) = .{},
    normals: std.ArrayList([3]f32) = .{},
    uvs: std.ArrayList([2]f32) = .{},
    face_vertices: std.ArrayList(u32) = .{},
    indices: std.ArrayList(Index) = .{},
    face_parsing_state: FaceParsingState = .undefined,

    fn deinit(self: *ParseContext) void {
        self.vertices.deinit(self.allocator);
        self.normals.deinit(self.allocator);
        self.material_ranges.deinit(self.allocator);
        self.uvs.deinit(self.allocator);
        self.face_vertices.deinit(self.allocator);
        self.indices.deinit(self.allocator);
    }
};

const FaceParsingState = enum {
    undefined,
    uvs,
    no_uvs,
};

pub fn parseFile(a: std.mem.Allocator, filepath: []const u8) !ObjFile {
    const file = try std.fs.cwd().openFile(filepath, .{ .mode = .read_only });
    defer file.close();

    const file_size = try file.getEndPos();

    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();

    var ctx = ParseContext{
        .temp_alloc = arena_state.allocator(),
        .allocator = a,
        .line = 0,
        .line_content = "",
        .filename = filepath,
    };
    defer ctx.deinit();

    try ctx.vertices.append(ctx.allocator, .{ 0, 0, 0 });
    try ctx.normals.append(ctx.allocator, .{ 0, 0, 0 });
    try ctx.uvs.append(ctx.allocator, .{ 0, 0 });

    const file_content = try file.readToEndAlloc(ctx.temp_alloc, file_size);
    defer ctx.temp_alloc.free(file_content);

    try parseContent(&ctx, file_content);

    // Make sure the last object is added
    try addCurrentObject(&ctx);

    return ObjFile{
        .allocator = a,
        .objects = try ctx.objects.toOwnedSlice(a),

        .material_library_name = try a.dupe(u8, ctx.material_library_name),
        .vertices = try ctx.vertices.toOwnedSlice(a),
        .normals = try ctx.normals.toOwnedSlice(a),
        .uvs = try ctx.uvs.toOwnedSlice(a),
    };
}

fn parseContent(ctx: *ParseContext, content: []const u8) !void {
    var lines = std.mem.tokenizeAny(u8, content, "\n\r");
    while (lines.next()) |raw_line| {
        ctx.line += 1;
        ctx.line_content = raw_line;
        const line = std.mem.trim(u8, raw_line, " \t\r");

        if (line.len == 0) {
            continue;
        }

        if (line[0] == '#') {
            continue;
        }

        switch (line[0]) {
            'v' => {
                if (line.len < 2) {
                    logErr(ctx, "Unexpected end of file", .{});
                    return ParseError.UnexpectedEndOfFile;
                }
                switch (line[1]) {
                    ' ' => try parseVertex(ctx, line[1..]),
                    'n' => try parseNormal(ctx, line[2..]),
                    't' => try parseTextureCoords(ctx, line[2..]),
                    'p' => {
                        logWarn(ctx, "Points are not supported", .{});
                    },
                    else => {
                        logErr(ctx, "Unknown token: {s}", .{line[0..2]});
                        return ParseError.InvalidToken;
                    },
                }
            },
            'f' => try parseFace(ctx, line[1..]),
            'o' => try parseObject(ctx, line[1..]),
            'g' => {
                if (!std.mem.startsWith(u8, line, "g ")) {
                    logErr(ctx, "Unknown token at beginning of line: {s}", .{line});
                    return ParseError.InvalidToken;
                } else {
                    logWarn(ctx, "Groups are not supported. Group name: {s}", .{line[2..]});
                }
            },
            'm' => {
                if (std.mem.startsWith(u8, line, "mtllib")) {
                    try parseMaterial(ctx, line);
                } else {
                    logErr(ctx, "Unknown token at beginning of line: {s}", .{line});
                    return ParseError.InvalidToken;
                }
            },
            'u' => {
                if (std.mem.startsWith(u8, line, "usemtl")) {
                    const new_material = std.mem.trim(u8, line["usemtl".len..], " \t\r");
                    // flush current range if it has any indices
                    const current_index_count = @as(u32, @intCast(ctx.indices.items.len)) - ctx.current_range_first_index;
                    if (current_index_count > 0) {
                        try ctx.material_ranges.append(ctx.allocator, .{
                            .material_name = try ctx.allocator.dupe(u8, ctx.current_material_name),
                            .range = .{
                                .offset = ctx.current_range_first_index,
                                .range = current_index_count,
                            },
                        });
                        ctx.current_range_first_index = @intCast(ctx.indices.items.len);
                    }
                    ctx.current_material_name = new_material;
                } else {
                    logErr(ctx, "Unknown token at beginning of line: {s}", .{line});
                    return ParseError.InvalidToken;
                }
            },
            'l' => try parseLine(ctx, line[1..]),
            's' => {
                logWarn(ctx, "Smoothing groups are not supported", .{});
            },
            else => {
                logErr(ctx, "Unknown token: {c}", .{line[0]});
                return ParseError.InvalidToken;
            },
        }
    }
}

fn parseValues(ctx: *ParseContext, line: []const u8, values: []f32, type_name: []const u8) !u32 {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    var count: u32 = 0;
    while (it.next()) |pos| {
        if (count > values.len) {
            logErr(ctx, "Too many values for {s}. Expected: {}, Found: {}", .{ type_name, values.len, count });
            return ParseError.InvalidEntry;
        }

        values[count] = std.fmt.parseFloat(f32, pos) catch {
            logErr(ctx, "Invalid number: {s}", .{pos});
            return ParseError.InvalidNumber;
        };

        count += 1;
    }

    return count;
}

fn parseLine(ctx: *ParseContext, line: []const u8) !void {
    var it = std.mem.tokenizeAny(u8, line, " \t");
    var count: u32 = 0;
    while (it.next()) |token| {
        var pos_index = std.fmt.parseInt(i32, token, 10) catch {
            logErr(ctx, "Invalid line element. Invalid index: {s}", .{token});
            return ParseError.InvalidIndex;
        };

        if (pos_index < 0) {
            pos_index = @as(i32, @intCast(ctx.vertices.items.len)) + pos_index;
        }
        if (pos_index < 0 or pos_index >= ctx.vertices.items.len) {
            logErr(ctx, "Invalid line element. Index out of bounds: {}", .{pos_index});
            return ParseError.InvalidIndex;
        }

        const index = Index{
            .vertex = @as(u32, @intCast(pos_index)),
            .uv = 0,
            .normal = 0,
        };
        try ctx.indices.append(ctx.allocator, index);
        count += 1;
    }

    if (count < 2) {
        logErr(ctx, "Invalid line element. Expected at least 2 indices, found: {}", .{count});
        return ParseError.InvalidEntry;
    }

    // store count like faces do so addCurrentObject knows how many verts per element
    try ctx.face_vertices.append(ctx.allocator, count);
}

inline fn parseVertex(ctx: *ParseContext, line: []const u8) !void {
    var values = [4]f32{ 0.0, 0.0, 0.0, 1.0 };
    const read = try parseValues(ctx, line, values[0..], "vertex");

    if (read < 3) {
        logErr(ctx, "Invalid vertex. Expected at least 3 values", .{});
        return ParseError.InvalidEntry;
    }

    if (read > 3) {
        logWarn(ctx, "Ignoring w component of vertex", .{});
    }

    try ctx.vertices.append(ctx.allocator, .{ values[0], values[1], values[2] });
}

inline fn parseNormal(ctx: *ParseContext, line: []const u8) !void {
    var values = [3]f32{ 0.0, 0.0, 0.0 };
    const read = try parseValues(ctx, line, values[0..], "normal");

    if (read < 3) {
        logErr(ctx, "Invalid normal. Expected 3 values, found: {}", .{read});
        return ParseError.InvalidEntry;
    }

    try ctx.normals.append(ctx.allocator, .{ values[0], values[1], values[2] });
}

inline fn parseTextureCoords(ctx: *ParseContext, line: []const u8) !void {
    var values = [4]f32{ 0.0, 0.0, 0.0, 0.0 };
    const read = try parseValues(ctx, line, values[0..], "texture coordinates");

    if (read > 2) {
        logWarn(ctx, "Ignoring z component of texture coordinate", .{});
    }

    try ctx.uvs.append(ctx.allocator, values[0..2].*);
}

inline fn parseFace(ctx: *ParseContext, line: []const u8) !void {
    var vertices_it = std.mem.tokenizeAny(u8, line, " \t");
    var vertices_count: u32 = 0;
    while (vertices_it.next()) |vertex| {
        var index_it = std.mem.splitScalar(u8, vertex, '/');
        const pos = index_it.next() orelse {
            logErr(ctx, "Invalid face. Position index is missing for vertex: {s}", .{vertex});
            return ParseError.InvalidEntry;
        };

        const uv = index_it.next() orelse {
            logErr(ctx, "Invalid face. UV index is missing for vertex: {s}", .{vertex});
            return ParseError.InvalidEntry;
        };

        const norm = index_it.next() orelse {
            logErr(ctx, "Invalid face. Normal index is missing for vertex: {s}", .{vertex});
            return ParseError.InvalidEntry;
        };

        // Ensure consistency between faces with and without uv coordinates
        if (norm.len == 0) {
            if (ctx.face_parsing_state == .uvs) {
                logErr(ctx, "Invalid face. Mismatch between face with and without uv coordinates.", .{});
                return ParseError.InvalidEntry;
            } else ctx.face_parsing_state = .no_uvs;
        } else {
            if (ctx.face_parsing_state == .no_uvs) {
                logErr(ctx, "Invalid face. Mismatch between face with and without uv coordinates.", .{});
                return ParseError.InvalidEntry;
            } else ctx.face_parsing_state = .uvs;
        }

        var pos_index = std.fmt.parseInt(i32, pos, 10) catch {
            logErr(ctx, "Invalid face. Invalid position index: {s}", .{pos});
            return ParseError.InvalidIndex;
        };

        var uv_index = if (uv.len == 0) blk: {
            if (ctx.uvs.items.len == 0) {
                const zero: f32 = 0.0;
                try ctx.uvs.append(ctx.allocator, .{ zero, zero });
            }
            break :blk 0;
        } else std.fmt.parseInt(i32, uv, 10) catch {
            logErr(ctx, "Invalid face. Invalid uv index: {s}", .{uv});
            return ParseError.InvalidIndex;
        };

        // FIXME:This is not technically correct, as normals are optional. Revise this later.
        var norm_index = std.fmt.parseInt(i32, norm, 10) catch {
            logErr(ctx, "Invalid face. Invalid normal index: {s}", .{norm});
            return ParseError.InvalidIndex;
        };

        if (pos_index < 0) {
            pos_index = @as(i32, @intCast(ctx.vertices.items.len)) + pos_index;
        }
        if (pos_index < 0 or pos_index >= ctx.vertices.items.len) {
            logErr(ctx, "Invalid face. Position index out of bounds: {s}. Index: {}, Expected between: [0, {}]", .{ pos, pos_index, ctx.vertices.items.len - 1 });
            return ParseError.InvalidIndex;
        }

        if (uv_index < 0) {
            uv_index = @as(i32, @intCast(ctx.uvs.items.len)) + uv_index;
        }
        if (uv_index < 0 or uv_index >= ctx.uvs.items.len) {
            logErr(ctx, "Invalid face. UV index out of bounds: {s}. Index: {}, Expected between: [0, {}]", .{ uv, uv_index, ctx.uvs.items.len - 1 });
            return ParseError.InvalidIndex;
        }

        if (norm_index < 0) {
            norm_index = @as(i32, @intCast(ctx.normals.items.len)) + norm_index;
        }
        if (norm_index < 0 or norm_index >= ctx.normals.items.len) {
            logErr(ctx, "Invalid face. Normal index out of bounds: {s}. Index: {}, Expected between: [0, {}]", .{ norm, norm_index, ctx.normals.items.len - 1 });
            return ParseError.InvalidIndex;
        }

        const index = Index{
            .vertex = @as(u32, @intCast(pos_index)),
            .uv = @as(u32, @intCast(uv_index)),
            .normal = @as(u32, @intCast(norm_index)),
        };
        try ctx.indices.append(ctx.allocator, index);
        vertices_count += 1;
    }

    if (vertices_count < 3) {
        logErr(ctx, "Invalid face. Expected at least 3 vertices, found: {}", .{vertices_count});
        return ParseError.InvalidEntry;
    }

    try ctx.face_vertices.append(ctx.allocator, vertices_count);
}

inline fn parseObject(ctx: *ParseContext, line: []const u8) !void {
    try addCurrentObject(ctx);
    ctx.object_name = std.mem.trim(u8, line, " \t\r");
}

inline fn parseMaterial(ctx: *ParseContext, line: []const u8) !void {
    ctx.material_library_name = std.mem.trim(u8, line["mtllib".len..], " \t\r");
}

fn addCurrentObject(ctx: *ParseContext) !void {
    if (ctx.face_vertices.items.len > 0) {
        // flush final material range
        const current_index_count = @as(u32, @intCast(ctx.indices.items.len)) - ctx.current_range_first_index;
        if (current_index_count > 0) {
            try ctx.material_ranges.append(ctx.allocator, .{
                .material_name = try ctx.allocator.dupe(u8, ctx.current_material_name),
                .range = .{
                    .offset = ctx.current_range_first_index,
                    .range = current_index_count,
                },
            });
            ctx.current_range_first_index = @intCast(ctx.indices.items.len);
        }

        try ctx.objects.append(ctx.allocator, .{
            .name = try ctx.allocator.dupe(u8, ctx.object_name),
            .material_name = try ctx.allocator.dupe(u8, ctx.current_material_name),
            .face_vertices = try ctx.allocator.dupe(u32, ctx.face_vertices.items),
            .indices = try ctx.allocator.dupe(Index, ctx.indices.items),
            .material_ranges = try ctx.allocator.dupe(MaterialInfo, ctx.material_ranges.items),
        });

        ctx.face_vertices.clearRetainingCapacity();
        ctx.indices.clearRetainingCapacity();
        ctx.material_ranges.clearRetainingCapacity();
        ctx.current_range_first_index = 0;
    }
}

inline fn logErr(ctx: *ParseContext, comptime msg: []const u8, args: anytype) void {
    log.err("{s}: {}: " ++ msg ++ "\nLine content: {s}", .{ ctx.filename, ctx.line } ++ args ++ .{ctx.line_content});
}

inline fn logWarn(ctx: *ParseContext, comptime msg: []const u8, args: anytype) void {
    log.warn("{s}: {}: " ++ msg, .{ ctx.filename, ctx.line } ++ args);
}
