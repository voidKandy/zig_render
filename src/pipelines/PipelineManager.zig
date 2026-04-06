const std = @import("std");
const Allocator = std.mem.Allocator;
const log = std.log.scoped(.PipelineManager);
const engine = @import("../root.zig");
const vki = engine.vulkan_init;
const frames_mod = engine.frames;
const descriptor = engine.descriptor;
const vk = engine.clibs.vk;
const Pipeline = @import("Pipeline.zig");

const Type = enum { single, map };

pub const Entry = union(Type) {
    single: Pipeline,
    map: std.StringHashMap(Pipeline),
};

all_graphics: std.StringHashMap(Entry),
all_compute: std.StringHashMap(Entry),

pub fn init(a: Allocator) @This() {
    return .{
        .all_graphics = std.StringHashMap(Entry).init(a),
        .all_compute = std.StringHashMap(Entry).init(a),
    };
}

pub fn deinit(self: *@This(), allocs: *engine.VulkanEngine.Allocators, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) void {
    var iter = self.all_graphics.valueIterator();
    while (iter.next()) |entry| {
        switch (entry.*) {
            .single => |s| s.deinit(allocs, device, alloc_cbs),
            .map => |*m| {
                defer m.deinit();
                var it = m.valueIterator();
                while (it.next()) |obj|
                    obj.*.deinit(allocs, device, alloc_cbs);
            },
        }
    }
    self.all_graphics.deinit();

    iter = self.all_compute.valueIterator();
    while (iter.next()) |entry| {
        switch (entry.*) {
            .single => |s| s.deinit(allocs, device, alloc_cbs),
            .map => |*m| {
                defer m.deinit();
                var it = m.valueIterator();
                while (it.next()) |obj|
                    obj.*.deinit(allocs, device, alloc_cbs);
            },
        }
    }
    self.all_compute.deinit();
}

pub fn runDraw(self: @This(), which: enum { graphics, compute }, dd: Pipeline.DrawData, cmd: vk.CommandBuffer) void {
    const outer_map = switch (which) {
        .graphics => self.all_graphics,
        .compute => self.all_compute,
    };
    var iter = outer_map.valueIterator();

    while (iter.next()) |entry| {
        switch (entry.*) {
            .single => |s| s.draw(dd, cmd),
            .map => |m| {
                var it = m.valueIterator();
                while (it.next()) |obj| obj.draw(dd, cmd);
            },
        }
    }
}

pub fn runDrawImgui(self: @This(), which: enum { graphics, compute }) void {
    const outer_map = switch (which) {
        .graphics => self.all_graphics,
        .compute => self.all_compute,
    };
    var iter = outer_map.valueIterator();

    while (iter.next()) |entry| {
        switch (entry.*) {
            .single => |s| if (s.drawImguiFunc != null) s.drawImgui(),
            .map => |m| {
                var it = m.valueIterator();
                while (it.next()) |obj| if (obj.drawImguiFunc != null) obj.drawImgui();
            },
        }
    }
}

pub fn insert(self: *@This(), a: Allocator, which: enum { graphics, compute }, name: []const u8, key: ?[]const u8, obj: Pipeline) Allocator.Error!void {
    var outer_map: *std.StringHashMap(Entry) = switch (which) {
        .graphics => &self.all_graphics,
        .compute => &self.all_compute,
    };
    const ptr_opt = outer_map.getPtr(name);

    if (key) |k|
        return if (ptr_opt) |ptr| {
            if (ptr.* != .map) @panic("Tried to insert map type into entry marked as non-map");
            try ptr.map.put(k, obj);
        } else {
            var map = std.StringHashMap(Pipeline).init(a);
            try map.put(k, obj);
            try outer_map.put(name, .{ .map = map });
        };

    if (ptr_opt != null) @panic("Tried to overlap single entry");
    try outer_map.put(name, .{ .single = obj });
}
