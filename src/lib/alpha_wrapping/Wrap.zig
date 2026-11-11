const std = @import("std");
const log = std.log.scoped(.AlphaWrap);
const shared = @import("shared.zig");
const core = @import("../../root.zig");
const math_mod = core.lib.math;
const mesh_mod = core.lib.mesh;
const Allocator = std.mem.Allocator;
const Delaunay = core.lib.alpha_wrapping.Delaunay;
const Oracle = core.lib.alpha_wrapping.Oracle;
const Vec3 = shared.Vec3;

fn triSquaredCircumradius(a: Vec3, b: Vec3, c: Vec3) f64 {
    const ab = b.sub(a);
    const ac = c.sub(a);
    const n = ab.cross(ac);
    const n2 = n.squaredNorm();
    if (n2 <= 0) return std.math.inf(f64); // degenerate triangle
    return ab.squaredNorm() * c.sub(b).squaredNorm() * ac.squaredNorm() / (4.0 * n2);
}

pub const Mesh = struct {
    vertices: std.ArrayListUnmanaged(Vec3),
    faces: std.ArrayListUnmanaged([3]u32),

    pub fn deinit(self: *@This(), alloc: Allocator) void {
        self.vertices.deinit(alloc);
        self.faces.deinit(alloc);
    }
};

const Gate = struct {
    r2: f64,
    outside: shared.CellId,
    fi: usize,
    facet_vertex_snapshot: [3]shared.VertexId, // sorted facet-vertex snapshot for staleness check

};

fn sortedFacet(del: Delaunay, c: shared.CellId, fi: usize) [3]shared.VertexId {
    const cc = del.cellAt(c).?;
    var f = [_]shared.VertexId{
        cc.vertices[@trunc(Delaunay.FACET[fi].x)],
        cc.vertices[@trunc(Delaunay.FACET[fi].y)],
        cc.vertices[@trunc(Delaunay.FACET[fi].z)],
    };

    std.mem.sort(
        shared.VertexId,
        &f,
        .{},
        struct {
            fn lessThan(_: @TypeOf(.{}), a: shared.VertexId, b: shared.VertexId) bool {
                return a < b;
            }
        }.lessThan,
    );

    return f;
}

const WrapParams = struct {
    alpha: f64 = 0,
    offset: f64 = 0,
    manifold: bool = true,
};

pub const WrapStats = struct {
    steiner_points: u32 = 0,
    rule1: u32 = 0,
    rule2: u32 = 0,
    carved: u32 = 0,
    gates_popped: u32 = 0,
    manifold_cells_reclaimed: u32 = 0,
    output_vertices: u32 = 0,
    output_faces: u32 = 0,
};

const Label = enum(u8) {
    inside = 0,
    outside = 1,
    manifold = 2,
};

const Wrap = @This();

oracle: Oracle,
delaunay: Delaunay = .{},
labels: std.ArrayListUnmanaged(Label) = .empty,
params: WrapParams = .{},
stats: WrapStats = .{},
alpha2: f64 = 0.0,
first_real_vertex: shared.VertexId = 0, // ids < this are super/bbox scaffolding

fn deinit(self: *@This(), a: Allocator) void {
    self.delaunay.deinit(a);
    self.labels.deinit(a);
    self.oracle.deinit(a);
}

fn labelOf(self: *const @This(), c: shared.CellId) Label {
    return self.labels.items[@intCast(c)];
}

fn setLabel(self: *@This(), c: shared.CellId, l: Label) void {
    self.labels.items[@intCast(c)] = l;
}

fn isSolid(self: *const @This(), c: shared.CellId) bool {
    return self.labelOf(c) != .outside;
}
//   void ensure_label_capacity();

//   bool facet_touches_scaffold(Cid c, int fi) const;

fn ensureLabelCapacity(self: *@This(), a: Allocator) Allocator.Error!void {
    const labels_len = self.labels.items.len;
    const cells_len = self.delaunay.cells.items.len;
    if (labels_len < cells_len) {
        try self.labels.resize(a, cells_len);
        if (cells_len > labels_len) {
            @memset(self.labels.items[labels_len..], .outside);
        }
    }
}

fn facetTouchesScaffold(self: *const @This(), c: shared.CellId, fi: usize) bool {
    const cc = self.delaunay.cellAt(c).?;
    inline for (shared.Vec3.FIELDS) |s| {
        if (cc.vertices[@trunc(@field(Delaunay.FACET[fi], s))] < self.first_real_vertex) return true;
    }

    return false;
}

/// Outward unit normal of facet fi of cell c (pointing away from c's interior).
fn facetOutwardNormal(self: *const @This(), c: shared.CellId, fi: usize) Vec3 {
    const cc = self.delaunay.cellAt(c).?;
    const a = self.delaunay.pointAt(cc.vertices[@trunc(Delaunay.FACET[fi].x)]).?;
    const b = self.delaunay.pointAt(cc.vertices[@trunc(Delaunay.FACET[fi].y)]).?;
    const d = self.delaunay.pointAt(cc.vertices[@trunc(Delaunay.FACET[fi].z)]).?;
    const n = b.sub(a).cross(d.sub(a));
    const len = n.norm();
    return if (len > 0) n.div(len) else n;
}

/// Squared radius of the smallest empty sphere through the gate facet
/// (crossing-aware); used vs alpha^2. Returns +inf for permissive gates.
fn gateSquaredRadius(self: *const @This(), outside: shared.CellId, fi: usize, inside: shared.CellId) f64 {
    if (self.delaunay.cellIsOuter(outside) or
        self.delaunay.cellIsOuter(inside) or
        self.facetTouchesScaffold(outside, fi))
    {
        // permissive
        return std.math.inf(f64);
    }

    const oc = self.delaunay.cellAt(outside).?;
    const p1 = self.delaunay.pointAt(oc.vertices[@trunc(Delaunay.FACET[fi].x)]).?;
    const p2 = self.delaunay.pointAt(oc.vertices[@trunc(Delaunay.FACET[fi].y)]).?;
    const p3 = self.delaunay.pointAt(oc.vertices[@trunc(Delaunay.FACET[fi].z)]).?;
    const cc_out: Vec3 = self.delaunay.circumcenter(outside);
    const cc_in = self.delaunay.circumcenter(inside);
    const s1 = shared.orient3d(p1, p2, p3, cc_out);
    const s2 = shared.orient3d(p1, p2, p3, cc_in);
    if (s1 != s2) {
        // Dual Voronoi edge crosses the facet: min empty-sphere radius is the
        // facet's own circumradius.
        return triSquaredCircumradius(p1, p2, p3);
    }

    return @min(
        self.delaunay.squaredCircumradius(outside),
        self.delaunay.squaredCircumradius(inside),
    );
}

fn gateTraversable(self: *const @This(), outside: shared.CellId, fi: usize, inside: shared.CellId) bool {
    return gateSquaredRadius(outside, fi, inside) > self.alpha2;
}

fn computeSteinerPoint(
    self: *const @This(),
    alloc: Allocator,
    outside: shared.CellId,
    fi: usize,
    inside: shared.CellId,
    out: *Vec3,
    rule: *usize,
) Allocator.Error!bool {
    const inner_cell = self.delaunay.circumcenter(inside);
    const outer_cell = if (!self.delaunay.cellIsOuter(outside)) self.delaunay.circumcenter(outside) else vec: {
        // Outer cell models an infinite cell: the dual Voronoi edge is a ray from
        // cc_in outward through the facet. Use a far point along that ray.
        var back: shared.CellId = -1;
        const ic = self.delaunay.cellAt(inside).?;
        for (0..4) |k| {
            if (ic.cells[k] == outside) {
                back = @intCast(k);
                break;
            }
        }
        const n: Vec3 = if (back >= 0)
            self.facetOutwardNormal(inside, @intCast(back))
        else
            self.facetOutwardNormal(outside, fi).mul(-1.0);
        const l = 3.0 * self.oracle.bounding_box.diagonal() + 1.0;
        break :vec inner_cell.add(n.mul(l));
    };

    // Rule 1: dual edge crosses the offset iso-surface.
    var s = Vec3.ZERO;
    if (self.oracle.firstOffsetCrossing(outer_cell, inner_cell, self.params.offset, &s)) {
        out.* = s;
        rule.* = 1;
        return true;
    }
    // Rule 2: inside cell still overlaps the input.
    const ic = self.delaunay.cellAt(inside).?;
    const a = self.delaunay.pointAt(@intCast(ic.vertices[0])).?;
    const b = self.delaunay.pointAt(@intCast(ic.vertices[1])).?;
    const c = self.delaunay.pointAt(@intCast(ic.vertices[2])).?;
    const d = self.delaunay.pointAt(@intCast(ic.vertices[3])).?;
    if (try self.oracle.doIntersectTet(alloc, a, b, c, d)) {
        const p = self.oracle.closestPoint(inner_cell);
        const dir = inner_cell.sub(p);
        const len = dir.norm();
        out.* = if (len > 0)
            p.add(dir.mul(self.params.offset / len))
        else
            p.add(Vec3.make(self.params.offset, 0, 0));
        rule.* = 2;
        return true;
    }

    return false;
}

const GateQueue =
    std.PriorityQueue(Gate, @TypeOf(.{}), struct {
        fn c(_: @TypeOf(.{}), a: Gate, b: Gate) std.math.Order {
            return std.math.order(b.r2, a.r2);
        }
    }.c);

const DEFAULT_MARGIN = 1000.0;
fn makeMesh(
    self: *@This(),
    alloc: Allocator,
    tris: []const shared.Triangle,
    params: WrapParams,
) Allocator.Error!Mesh {
    self.params = params;
    self.stats = .{};
    self.alpha2 = params.alpha * params.alpha;
    self.oracle = try Oracle.build(alloc, tris);

    // ---- loose bounding box: scale 1.2 about center, expand by sqrt(3)*offset ----
    const ib = self.oracle.bounding_box;
    const center = ib.center();
    const extents = ib.extents().mul(1.2);
    const offset: f32 = @floatCast(@sqrt(3.0) * self.params.offset);
    const loose = shared.Aabb{
        .min = center.sub(extents).sub(.make(offset, offset, offset)),
        .max = center.add(extents).add(.make(offset, offset, offset)),
    };

    log.debug("bbox min=({d},{d},{d}) max=({d},{d},{d})", .{
        loose.min.x, loose.min.y, loose.min.z,
        loose.max.x, loose.max.y, loose.max.z,
    });

    self.delaunay.deinit(alloc);
    self.delaunay = try Delaunay.init(
        alloc,
        loose,
        DEFAULT_MARGIN,
    );
    // Insert 8 loose-bbox corners (scaffolding). ids 4..11 (super verts are 0..3).

    for (0..8) |i| {
        const corner = Vec3.make(
            if ((i & 1) != 0) loose.max.x else loose.min.x,
            if ((i & 2) != 0) loose.max.y else loose.min.y,
            if ((i & 4) != 0) loose.max.z else loose.min.z,
        );

        var new_cells = std.ArrayListUnmanaged(shared.CellId).empty;
        defer new_cells.deinit(alloc);

        _ = try self.delaunay.insert(alloc, corner, &new_cells);
    }
    self.first_real_vertex = @intCast(self.delaunay.points.items.len); // = 12

    try self.labels.ensureTotalCapacity(alloc, self.delaunay.cells.items.len);

    for (0..self.delaunay.cells.items.len) |_|
        self.labels.appendAssumeCapacity(.outside);

    for (0..self.delaunay.cells.items.len) |i| {
        const c: shared.CellId = @intCast(i);
        if (!self.delaunay.cellAlive(c)) continue;
        self.setLabel(c, if (self.delaunay.cellIsOuter(c)) .outside else .inside);
    }

    {
        var n_in: usize = 0;
        var n_out: usize = 0;
        for (0..self.delaunay.cells.items.len) |i| {
            const c: shared.CellId = @intCast(i);
            if (!self.delaunay.cellAlive(c)) continue;
            if (self.labelOf(c) == .inside) n_in += 1 else n_out += 1;
        }
        log.debug("inside={d} outside={d}", .{ n_in, n_out });
        log.debug("cellAt(0) null={} cellAlive(0)={} flag0={}", .{
            self.delaunay.cellAt(0) == null,
            self.delaunay.cellAlive(0),
            self.delaunay.cells.items[0].alive,
        });

        for (self.delaunay.cells.items, 0..) |cell, i| {
            if (!cell.alive) continue;
            log.debug("cell {d}: v={any} outer={}", .{ i, cell.vertices, self.delaunay.cellIsOuter(@intCast(i)) });
        }
        for (0..4) |v| log.debug("super {d} = {any}", .{ v, self.delaunay.pointAt(@intCast(v)) });
    }
    var pq = GateQueue.initContext(.{});
    defer pq.deinit(alloc);

    // Seed with all traversable outside/inside gates.
    for (0..self.delaunay.cells.items.len) |i| {
        const c: shared.CellId = @intCast(i);
        if (!self.delaunay.cellAlive(c) or self.labelOf(c) != .outside) continue;
        for (0..4) |k| try Helpers.enque(self, alloc, &pq, c, k);
    }

    const max_steiner = 5_000_000;
    var new_cells = std.ArrayListUnmanaged(shared.CellId).empty;
    defer new_cells.deinit(alloc);

    while (pq.pop()) |g| {
        self.stats.gates_popped += 1;

        // Validate against staleness (cell recycling / relabeling).
        if (!self.delaunay.cellAlive(g.outside) or self.labelOf(g.outside) != .outside) continue;
        const inside = self.delaunay.cellAt(g.outside).?.cells[g.fi];
        if (inside == shared.NO_CELL or !self.delaunay.cellAlive(inside) or
            self.labelOf(inside) != .inside)
            continue;
        if (!std.mem.eql(
            shared.VertexId,
            &sortedFacet(self.delaunay, g.outside, g.fi),
            &g.facet_vertex_snapshot,
        )) continue;

        var sp = Vec3.ZERO;
        var rule: usize = 0;
        const hit = try self.computeSteinerPoint(alloc, g.outside, g.fi, inside, &sp, &rule);

        if (self.stats.gates_popped <= 12) log.debug(
            "pop {d}: r2={d} outside={d} inside={d} steiner={} rule={d} sp={any}",
            .{ self.stats.gates_popped, g.r2, g.outside, inside, hit, rule, sp },
        );
        if (hit) {
            if (self.stats.steiner_points >= max_steiner) break;
            _ = try self.delaunay.insert(alloc, sp, &new_cells);

            self.stats.steiner_points += 1;
            if (rule == 1) self.stats.rule1 += 1 else self.stats.rule2 += 1;
            try self.ensureLabelCapacity(alloc);

            for (new_cells.items) |nc| {
                self.setLabel(nc, if (self.delaunay.cellIsOuter(nc)) .outside else .inside);
                // Enqueue every new outside/inside boundary gate.
                for (0..4) |fi| {
                    const m = self.delaunay.cellAt(nc).?.cells[fi];
                    if (m == shared.NO_CELL or !self.delaunay.cellAlive(m)) continue;
                    if (self.labelOf(nc) == .outside and self.labelOf(m) == .inside) {
                        try Helpers.enque(self, alloc, &pq, nc, fi);
                    } else if (self.labelOf(nc) == .inside and self.labelOf(m) == .outside) {
                        var back: i32 = -1;
                        for (0..4) |k| {
                            if (self.delaunay.cellAt(m).?.cells[k] == nc) {
                                back = @intCast(k);
                                break;
                            }
                        }

                        if (back >= 0) try Helpers.enque(self, alloc, &pq, m, @intCast(back));
                    }
                }
            }
        } else {
            // Carve: flip the inside cell to OUTSIDE and open its other 3 facets.
            self.setLabel(inside, .outside);
            self.stats.carved += 1;

            for (0..4) |fi| {
                const m = self.delaunay.cellAt(inside).?.cells[fi];
                if (m == shared.NO_CELL or !self.delaunay.cellAlive(m)) continue;
                if (self.labelOf(m) == .inside) try Helpers.enque(self, alloc, &pq, inside, fi);
            }
        }
    }

    log.debug("AFTER LOOP: popped={d} carved={d} steiner={d}", .{
        self.stats.gates_popped, self.stats.carved, self.stats.steiner_points,
    });

    if (self.params.manifold) try self.makeManifold(alloc);

    const mesh = try self.extract(alloc);
    self.stats.output_vertices = @intCast(mesh.vertices.items.len);
    self.stats.output_faces = @intCast(mesh.faces.items.len);
    return mesh;
}

fn makeManifold(wrap: *Wrap, alloc: Allocator) Allocator.Error!void {
    // Build vertex -> incident live cells (labels change during the pass, but the
    // incidence relation does not, since no points are inserted here).
    var incident: std.AutoHashMapUnmanaged(shared.VertexId, std.ArrayListUnmanaged(shared.CellId)) = .empty;
    defer {
        var iter = incident.valueIterator();
        while (iter.next()) |v|
            v.deinit(alloc);
        incident.deinit(alloc);
    }

    for (0..wrap.delaunay.cells.items.len) |i| {
        const c: shared.CellId = @intCast(i);
        if (!wrap.delaunay.cellAlive(c)) continue;
        const cc = wrap.delaunay.cellAt(c).?;
        for (0..4) |k| {
            const key = cc.vertices[k];
            var entry = try incident.getOrPut(alloc, key);
            if (!entry.found_existing) entry.value_ptr.* = .empty;
            try entry.value_ptr.append(alloc, @intCast(c));
        }
    }

    var stack = try std.ArrayListUnmanaged(shared.VertexId).initCapacity(alloc, incident.size);
    defer stack.deinit(alloc);

    var iter = incident.keyIterator();

    while (iter.next()) |v| {
        if (v.* >= wrap.first_real_vertex and try Helpers.nonManifold(wrap, alloc, &incident, v.*))
            stack.appendAssumeCapacity(v.*);
    }

    var guard: u32 = 0;
    const guard_max: u32 = 20_000_000;

    while (stack.pop()) |v| {
        guard += 1;
        if (guard > guard_max) break;

        if (!try Helpers.nonManifold(wrap, alloc, &incident, v)) continue;

        // Candidate finite OUTSIDE cells incident to v, preference-ordered.
        const cells = incident.get(v).?;
        var cand = try std.ArrayListUnmanaged(shared.CellId).initCapacity(alloc, cells.items.len);
        defer cand.deinit(alloc);

        for (cells.items) |c| {
            if (!wrap.isSolid(c) and !wrap.delaunay.cellIsOuter(c)) cand.appendAssumeCapacity(c);
        }
        if (cand.items.len == 0) continue; // only exterior outside cells; cannot fix here

        std.mem.sort(shared.CellId, cand.items, wrap, struct {
            fn lessThan(
                wr: *const Wrap,
                a: shared.CellId,
                b: shared.CellId,
            ) bool {
                const sa = Helpers.hasScaffold(wr, a);
                const sb = Helpers.hasScaffold(wr, b);
                if (sa != sb) return !sa; // prefer cells without scaffold vertices
                return Helpers.cellLongestEdge(wr, a) < Helpers.cellLongestEdge(wr, b); // avoid spikes
            }
        }.lessThan);

        for (cand.items) |c| {
            if (!try Helpers.nonManifold(wrap, alloc, &incident, v)) break;
            wrap.setLabel(c, .manifold);
            wrap.stats.manifold_cells_reclaimed += 1;
            // Reclaiming c changes the boundary around its vertices; revisit them.
            const cc = wrap.delaunay.cellAt(c).?;
            for (0..4) |k| {
                if (cc.vertices[k] >= wrap.first_real_vertex and try Helpers.nonManifold(wrap, alloc, &incident, cc.vertices[k]))
                    try stack.append(alloc, cc.vertices[k]);
            }
        }
    }
}

fn extract(self: *@This(), alloc: Allocator) Allocator.Error!Mesh {
    var mesh = Mesh{
        .faces = .empty,
        .vertices = .empty,
    };
    var remap = std.AutoHashMapUnmanaged(shared.VertexId, usize).empty;
    defer remap.deinit(alloc);

    for (0..self.delaunay.cells.items.len) |i| {
        const c: shared.CellId = @intCast(i);
        if (!self.delaunay.cellAlive(c)) continue;
        if (self.labelOf(c) == .outside) continue; // only solid cells emit
        const cc = self.delaunay.cellAt(c).?;
        for (0..4) |fi| {
            const o = cc.cells[fi];
            const outside = (o == shared.NO_CELL) or (self.labelOf(o) == .outside);
            if (!outside) continue;
            // FACET triple normal points toward o (outward from the solid).
            const a = cc.vertices[@trunc(Delaunay.FACET[fi].x)];
            const b = cc.vertices[@trunc(Delaunay.FACET[fi].y)];
            const d = cc.vertices[@trunc(Delaunay.FACET[fi].z)];
            try mesh.faces.append(alloc, .{
                @intCast(try Helpers.getOrPutVert(self, alloc, &remap, &mesh, a)),
                @intCast(try Helpers.getOrPutVert(self, alloc, &remap, &mesh, b)),
                @intCast(try Helpers.getOrPutVert(self, alloc, &remap, &mesh, d)),
            });
        }
    }
    return mesh;
}

fn alphaWrap(alloc: Allocator, tris: []const shared.Triangle, params: WrapParams, stats: *WrapStats) Allocator.Error!Mesh {
    var wrap = Wrap{
        .oracle = .{
            .bounding_box = .empty(),
        },
        .params = params,
        .stats = stats.*,
    };

    defer wrap.deinit(alloc);

    const m = try makeMesh(&wrap, alloc, tris, params);
    stats.* = wrap.stats;
    return m;
}

/// Union find over a small local set (indices into a vector)
const Dsu = struct {
    p: std.ArrayListUnmanaged(u32) = .empty,
    fn deinit(self: *@This(), a: Allocator) void {
        self.p.deinit(a);
    }

    fn reset(self: *@This(), a: Allocator, n: usize) Allocator.Error!void {
        try self.p.resize(a, n);
        for (self.p.items, 0..) |*e, i| e.* = @intCast(i);
    }
    fn find(self: *const @This(), x: usize) usize {
        var cur = x;
        while (self.p.items[cur] != cur) {
            self.p.items[cur] = self.p.items[self.p.items[cur]];
            cur = self.p.items[cur];
        }
        return cur;
    }
    fn uni(self: *@This(), a: usize, b: usize) void {
        const ra = self.find(a);
        const rb = self.find(b);
        self.p.items[ra] = @intCast(rb);
    }
};

/// DO NOT ADD DATA FIELDS
/// (purely for encapsulation)
const Helpers = struct {
    fn enque(wrap: *const Wrap, a: Allocator, pq: *GateQueue, oc: shared.CellId, fi: usize) Allocator.Error!void {
        const cl = wrap.delaunay.cellAt(oc) orelse return;
        const inside = cl.cells[fi];
        if (inside == shared.NO_CELL or !wrap.delaunay.cellAlive(inside)) return;
        if (wrap.labelOf(oc) != .outside or wrap.labelOf(inside) != .inside) return;
        const r2 = wrap.gateSquaredRadius(oc, fi, inside);
        if (r2 <= wrap.alpha2) return; // not traversable
        try pq.push(a, Gate{
            .r2 = r2,
            .outside = oc,
            .fi = fi,
            .facet_vertex_snapshot = sortedFacet(wrap.delaunay, oc, fi),
        });
    }

    // Count connected components, among v's incident cells, of those satisfying
    // `want_solid`, where two incident cells connect if their shared facet
    // contains v. Returns component count (0 if none).
    fn components(
        wrap: *const Wrap,
        alloc: Allocator,
        incident_map: *std.AutoHashMapUnmanaged(shared.VertexId, std.ArrayListUnmanaged(shared.CellId)),
        v: shared.VertexId,
        want_solid: bool,
    ) Allocator.Error!usize {
        const cells = incident_map.get(v).?;

        var idx_map = std.AutoHashMapUnmanaged(shared.CellId, usize).empty;
        var members = std.ArrayListUnmanaged(shared.CellId).empty;

        defer {
            idx_map.deinit(alloc);
            members.deinit(alloc);
        }
        for (cells.items) |c| {
            if (wrap.isSolid(c) == want_solid) {
                try idx_map.put(alloc, c, members.items.len);
                try members.append(alloc, c);
            }
        }
        const m = members.items.len;
        if (m == 0) return 0;
        var dsu = Dsu{};
        defer dsu.deinit(alloc);
        try dsu.reset(alloc, m);
        std.debug.assert(dsu.p.items.len == m);
        std.debug.assert(dsu.p.items[m - 1] == m - 1);

        for (members.items, 0..) |c, i| {
            const cc = wrap.delaunay.cellAt((c)).?;
            for (0..4) |fi| {
                // facet fi contains v?
                var has_v = false;
                inline for (Vec3.FIELDS) |st| {
                    if (cc.vertices[@trunc(@field(Delaunay.FACET[fi], st))] == v) has_v = true;
                }
                if (!has_v) continue;
                const o = cc.cells[fi];
                if (o == shared.NO_CELL) continue;

                if (idx_map.get(o)) |val| {
                    dsu.uni(i, val);
                }
            }
        }
        var comps: usize = 0;
        for (0..m) |i| {
            if (dsu.find(i) == i) comps += 1;
        }

        return comps;
    }

    fn isBoundaryVertex(wrap: *const Wrap, incident_map: *std.AutoHashMapUnmanaged(shared.VertexId, std.ArrayListUnmanaged(shared.CellId)), v: shared.VertexId) bool {
        var solid = false;
        var out = false;
        const cells = incident_map.get(v).?;
        for (cells.items) |c| {
            if (wrap.isSolid(c)) solid = true else out = true;
        }
        return solid and out;
    }

    fn nonManifold(
        wrap: *const Wrap,
        alloc: Allocator,
        incident_map: *std.AutoHashMapUnmanaged(shared.VertexId, std.ArrayListUnmanaged(shared.CellId)),
        v: shared.VertexId,
    ) Allocator.Error!bool {
        if (!isBoundaryVertex(wrap, incident_map, v)) return false;
        // A manifold boundary vertex has a single solid umbrella and a single
        // outside umbrella.
        return try components(wrap, alloc, incident_map, v, true) > 1 or try components(wrap, alloc, incident_map, v, false) > 1;
    }

    fn cellLongestEdge(wrap: *const Wrap, c: shared.CellId) f64 {
        const cc = wrap.delaunay.cellAt(c).?;
        var mx: f64 = 0.0;

        for (0..4) |i| {
            for (0..4) |j| {
                mx = @max(
                    mx,
                    wrap.delaunay.pointAt(cc.vertices[i]).?.distSquared(wrap.delaunay.pointAt(cc.vertices[j]).?),
                );
            }
        }

        return mx;
    }

    fn hasScaffold(wrap: *const Wrap, c: shared.CellId) bool {
        const cc = wrap.delaunay.cellAt(c).?;
        for (0..4) |k| if (cc.vertices[k] < wrap.first_real_vertex) return true;
        return false;
    }

    fn getOrPutVert(
        wrap: *const Wrap,
        alloc: Allocator,
        remap: *std.AutoHashMapUnmanaged(shared.VertexId, usize),
        msh: *Mesh,
        v: shared.VertexId,
    ) Allocator.Error!usize {
        if (remap.get(v)) |val|
            return val;

        const id = msh.vertices.items.len;

        try remap.put(alloc, v, id);
        try msh.vertices.append(alloc, wrap.delaunay.pointAt(v).?);
        return id;
    }
};

// ---testing---
const testing = std.testing;
const tu = shared.testing_util;

// ---- adjust these imports to your project layout ----

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

const Bounds = struct { lo: Vec3, hi: Vec3 };

fn meshBbox(m: Mesh) Bounds {
    const inf = std.math.inf(f64);
    var lo = Vec3.make(inf, inf, inf);
    var hi = Vec3.make(-inf, -inf, -inf);
    for (m.vertices.items) |v| {
        lo = Vec3.make(@min(lo.x, v.x), @min(lo.y, v.y), @min(lo.z, v.z));
        hi = Vec3.make(@max(hi.x, v.x), @max(hi.y, v.y), @max(hi.z, v.z));
    }
    return .{ .lo = lo, .hi = hi };
}

/// Largest facet circumradius^2 in the output (skipping degenerate facets).
fn maxFacetR2(m: Mesh) f64 {
    var mx: f64 = 0;
    for (m.faces.items) |f| {
        const a = m.vertices.items[f[0]];
        const b = m.vertices.items[f[1]];
        const c = m.vertices.items[f[2]];
        const ab = b.sub(a);
        const ac = c.sub(a);
        const n2 = ab.cross(ac).squaredNorm();
        if (n2 <= 1e-24) continue;
        const r2 = ab.squaredNorm() * c.sub(b).squaredNorm() * ac.squaredNorm() / (4 * n2);
        mx = @max(mx, r2);
    }
    return mx;
}

/// Mirrors the C++ `alpha_wrap(soup, alpha, offset, manifold, &stats)` convenience wrapper.
/// Assumes alphaWrap has the signature
pub fn runWrap(
    alloc: Allocator,
    soup: []const shared.Triangle,
    alpha: f64,
    offset: f64,
    manifold: bool,
    stats: *WrapStats,
) !Mesh {
    const params = WrapParams{ .alpha = alpha, .offset = offset, .manifold = manifold };
    return alphaWrap(alloc, soup, params, stats);
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

test "cube_is_watertight_and_encloses" {
    const alloc = testing.allocator;

    const soup = try tu.unitCube(alloc);
    defer alloc.free(soup);

    const diag = @sqrt(3.0);
    const alpha = diag / 12.0;
    const offset = alpha / 10.0;

    var st = WrapStats{};
    var m = try runWrap(alloc, soup, alpha, offset, false, &st);
    defer m.deinit(alloc);

    const c = try tu.checkMesh(alloc, m);
    std.debug.print(
        "    cube: V={d} E={d} F={d} euler={d} closed={} oriented={} steiner={d}\n",
        .{ c.V, c.E, c.F, c.euler, c.closed, c.oriented, st.steiner_points },
    );

    try testing.expect(c.V > 0 and c.F > 0);
    try testing.expect(c.closed);
    try testing.expect(c.edge_manifold);
    try testing.expect(c.oriented);
    try testing.expectEqual(@as(i32, 2), c.euler); // genus 0
    try testing.expectEqual(@as(usize, 1), try tu.meshComponents(alloc, m));

    // Strict enclosure: output bbox contains the cube expanded by ~offset.
    const b = meshBbox(m);
    try testing.expect(b.lo.x <= 0.0 and b.lo.y <= 0.0 and b.lo.z <= 0.0);
    try testing.expect(b.hi.x >= 1.0 and b.hi.y >= 1.0 and b.hi.z >= 1.0);
    try testing.expect(b.lo.x <= -offset * 0.5 and b.hi.x >= 1.0 + offset * 0.5);

    // Facet size bound: circumradius^2 < alpha^2 (with a small tolerance).
    try testing.expect(maxFacetR2(m) <= alpha * alpha * 1.15);
}

test "sphere_band_and_facet_bound" {
    const alloc = testing.allocator;

    const soup = try tu.sphereSoup(alloc, Vec3.make(0, 0, 0), 1.0, 16, 24);
    defer alloc.free(soup);

    const diag = 2.0 * @sqrt(3.0); // ~bbox diagonal of a unit sphere's box
    const alpha = diag / 20.0;
    const offset = alpha / 15.0;

    var st = WrapStats{};
    var m = try runWrap(alloc, soup, alpha, offset, false, &st);
    defer m.deinit(alloc);

    const c = try tu.checkMesh(alloc, m);
    std.debug.print(
        "    sphere: V={d} F={d} euler={d} closed={} steiner={d}\n",
        .{ c.V, c.F, c.euler, c.closed, st.steiner_points },
    );

    try testing.expect(c.closed);
    try testing.expect(c.oriented);
    try testing.expectEqual(@as(i32, 2), c.euler);
    try testing.expectEqual(@as(usize, 1), try tu.meshComponents(alloc, m));

    // The real guarantee: every output vertex is strictly outside the input soup
    // and within the offset band (distance-to-soup in [~offset, offset+alpha]).
    var orc = try Oracle.build(alloc, soup); // NOTE: add `alloc` here if your Oracle.build takes one
    defer orc.deinit(alloc);

    var dlo: f64 = 1e9;
    var dhi: f64 = 0;
    for (m.vertices.items) |v| {
        // unsigned distance = |v - closest point on soup|
        const d = v.sub(orc.closestPoint(v)).norm();
        dlo = @min(dlo, d);
        dhi = @max(dhi, d);
    }
    std.debug.print(
        "    dist-to-soup band: [{d:.4}, {d:.4}] (offset={d:.4} alpha={d:.4})\n",
        .{ dlo, dhi, offset, alpha },
    );

    try testing.expect(dlo >= offset * 0.5); // strictly outside the input
    try testing.expect(dhi <= offset + alpha + 1e-6); // within the guaranteed band
    try testing.expect(maxFacetR2(m) <= alpha * alpha * 1.2);
}

test "single_triangle_makes_thin_shell" {
    const alloc = testing.allocator;

    const soup = [_]shared.Triangle{
        .{ Vec3.make(0, 0, 0), Vec3.make(1, 0, 0), Vec3.make(0, 1, 0) },
    };
    const alpha = 0.15;
    const offset = 0.02;

    var st = WrapStats{};
    var m = try runWrap(alloc, &soup, alpha, offset, false, &st);
    defer m.deinit(alloc);

    const c = try tu.checkMesh(alloc, m);
    std.debug.print(
        "    triangle: V={d} F={d} euler={d} closed={}\n",
        .{ c.V, c.F, c.euler, c.closed },
    );

    try testing.expect(c.V > 0);
    try testing.expect(c.closed);
    try testing.expect(c.oriented);
    try testing.expectEqual(@as(i32, 2), c.euler); // a closed shell around the flat triangle

    // Thickness ~ 2*offset: z-extent should be small and positive.
    const b = meshBbox(m);
    try testing.expect(b.hi.z - b.lo.z <= 4 * offset + alpha);
    try testing.expect(b.hi.z - b.lo.z > 0);
}

test "robust_to_defective_soup" {
    // A torus corrupted with flipped orientations, duplicate faces, and
    // degenerate (zero-area) triangles. The wrap must still be a clean closed,
    // oriented, vertex-manifold surface with the torus's genus 1 (euler 0), and
    // must not explode in size (degenerate faces are filtered).
    const alloc = testing.allocator;

    const clean = try tu.torusSoup(alloc, 1.0, 0.4, 48, 24);
    defer alloc.free(clean);

    var soup = std.ArrayListUnmanaged(shared.Triangle).empty;
    defer soup.deinit(alloc);

    for (clean, 0..) |tri, i| {
        var t = tri;
        if (i % 5 == 0) std.mem.swap(Vec3, &t[1], &t[2]); // flip orientation
        try soup.append(alloc, t);
        if (i % 7 == 0) try soup.append(alloc, t); // duplicate
    }

    // Degenerate triangles (zero area).
    for (0..30) |i| {
        const p = clean[i][0];
        try soup.append(alloc, .{ p, p, p });
        try soup.append(alloc, .{ p, clean[i][1], p });
    }

    const offset = 0.01;

    var stats = WrapStats{};
    var m = try runWrap(alloc, soup.items, 0.12, offset, true, &stats);
    defer m.deinit(alloc);

    const c = try tu.checkMesh(alloc, m);
    std.debug.print(
        "    defective torus: V={d} F={d} euler={d} closed={} vtx_manifold={}\n",
        .{ c.V, c.F, c.euler, c.closed, c.vertex_manifold },
    );

    try testing.expect(c.closed);
    try testing.expect(c.oriented);
    try testing.expect(c.vertex_manifold);
    try testing.expectEqual(@as(i32, 0), c.euler); // genus 1 recovered despite corruption
    try testing.expect(c.F < 6000); // no runaway refinement
}

test "torus_genus_depends_on_alpha" {
    // Torus: hole radius R-r = 0.6. A small alpha ball fits through the hole ->
    // genus 1 preserved (Euler = 0). A large alpha bridges the hole -> genus 0
    // (Euler = 2). This mirrors CGAL's documented topological-LOD behavior.
    const alloc = testing.allocator;

    const soup = try tu.torusSoup(alloc, 1.0, 0.4, 48, 24);
    defer alloc.free(soup);
    const offset = 0.01;

    {
        var s1 = WrapStats{};
        var keep = try runWrap(alloc, soup, 0.15, offset, false, &s1);
        defer keep.deinit(alloc);

        const ck = try tu.checkMesh(alloc, keep);
        std.debug.print(
            "    small-alpha torus: euler={d} closed={} comps={d}\n",
            .{ ck.euler, ck.closed, try tu.meshComponents(alloc, keep) },
        );
        try testing.expect(ck.closed);
        try testing.expect(ck.oriented);
        try testing.expectEqual(@as(i32, 0), ck.euler); // genus 1 preserved
    }

    {
        var s2 = WrapStats{};
        var fill = try runWrap(alloc, soup, 0.9, offset, false, &s2);
        defer fill.deinit(alloc);

        const cf = try tu.checkMesh(alloc, fill);
        std.debug.print(
            "    large-alpha torus: euler={d} closed={} comps={d}\n",
            .{ cf.euler, cf.closed, try tu.meshComponents(alloc, fill) },
        );
        try testing.expect(cf.closed);
        try testing.expectEqual(@as(i32, 2), cf.euler); // hole filled
    }
}

test "alpha_controls_gap_bridging" {
    // Two coplanar squares separated by a gap of width w in x.
    const alloc = testing.allocator;

    const w = 0.4;
    var soup = std.ArrayListUnmanaged(shared.Triangle).empty;
    defer soup.deinit(alloc);

    try tu.addQuad(alloc, &soup, Vec3.make(0, 0, 0), Vec3.make(1, 0, 0), Vec3.make(1, 1, 0), Vec3.make(0, 1, 0));
    try tu.addQuad(alloc, &soup, Vec3.make(1 + w, 0, 0), Vec3.make(2 + w, 0, 0), Vec3.make(2 + w, 1, 0), Vec3.make(1 + w, 1, 0));
    const offset = 0.03;

    // Large alpha (> w/2 by a lot): the ball can't fit through the gap -> bridged
    // into one connected shell.
    {
        var stbig = WrapStats{};
        var big = try runWrap(alloc, soup.items, 0.5, offset, false, &stbig);
        defer big.deinit(alloc);

        const cb = try tu.checkMesh(alloc, big);
        const comps = try tu.meshComponents(alloc, big);
        std.debug.print("    big-alpha: comps={d} closed={} F={d}\n", .{ comps, cb.closed, cb.F });
        std.debug.print("    big-alpha edges: boundary={d} nonmanifold={d}\n", .{ cb.boundary_edges, cb.nonmanifold_edges });
        try testing.expect(cb.closed);
        try testing.expectEqual(@as(usize, 1), comps);
    }

    // Small alpha (< w/2): the ball fits through the gap, wrapping each square
    // separately -> two components.
    {
        var stsmall = WrapStats{};
        var small = try runWrap(alloc, soup.items, 0.12, offset, false, &stsmall);
        defer small.deinit(alloc);

        const cs = try tu.checkMesh(alloc, small);
        const comps = try tu.meshComponents(alloc, small);
        std.debug.print("    small-alpha: comps={d} closed={} F={d}\n", .{ comps, cs.closed, cs.F });
        try testing.expect(cs.closed);
        try testing.expect(comps >= 2);
    }
}
