const std = @import("std");
const core = @import("../../root.zig");
const log = std.log.scoped(.SystemManager);
const vk = core.clibs.vk;
pub const Maze = @import("./Maze.zig");
pub const Debug = @import("./Debug.zig");
pub const Camera = @import("./Camera.zig");
pub const DrawBackground = @import("./DrawBackground.zig");

inline fn fnEql(a: std.builtin.Type.Fn, b: std.builtin.Type.Fn) bool {
    if (!std.meta.eql(a.calling_convention, b.calling_convention)) return false;
    if (a.is_generic != b.is_generic) return false;
    if (a.is_var_args != b.is_var_args) return false;
    if (a.return_type != b.return_type) return false;
    if (a.params.len != b.params.len) return false;

    for (a.params, b.params) |pa, pb| {
        if (pa.type != pb.type) return false;
        if (pa.is_generic != pb.is_generic) return false;
        if (pa.is_noalias != pb.is_noalias) return false;
    }
    return true;
}

fn formatFnSig(comptime fn_info: std.builtin.Type.Fn) []const u8 {
    comptime var params_str: []const u8 = "";
    inline for (fn_info.params, 0..) |param, i| {
        const type_name = if (param.type) |T| @typeName(T) else "anytype";
        params_str = params_str ++ (if (i == 0) "" else ", ") ++ type_name;
    }

    const return_name = if (fn_info.return_type) |R| @typeName(R) else "void";

    return std.fmt.comptimePrint("fn ({s}) {s}", .{ params_str, return_name });
}

fn shortTypeName(comptime full: []const u8) []const u8 {
    var it = std.mem.splitBackwardsScalar(u8, full, '.');
    return it.first();
}

/// Replaces params[0] (the `self` receiver) with an `anytype`-shaped
/// param, so signatures from different concrete system types can be
/// compared for equality without the receiver type getting in the way.
inline fn normalizeSelf(fn_info: std.builtin.Type.Fn) std.builtin.Type.Fn {
    var info = fn_info;
    if (info.params.len == 0) return info;

    const normalized_first: std.builtin.Type.Fn.Param = .{
        .type = null,
        .is_generic = true,
        .is_noalias = info.params[0].is_noalias,
    };

    const new_params = [_]std.builtin.Type.Fn.Param{normalized_first} ++ info.params[1..];
    info.params = new_params;
    return info;
}

/// completely removes the `self` argument from function type
/// this is for the register and update sets functions which don't actually
/// need access to self for each system, but does need access to self in the manager
inline fn removeSelf(fn_info: std.builtin.Type.Fn) std.builtin.Type.Fn {
    var info = fn_info;
    if (info.params.len == 0) return info;

    info.params = info.params[1..];
    return info;
}

pub const DrawImguiContext = struct {
    window: *core.clibs.sdl.Window,
    world: *core.engine.world.GameWorld,
    resources: *const core.resources.Manager,

    pub fn fromEngine(engine: *core.engine.Engine) @This() {
        return .{
            .window = engine.window,
            .world = &engine.world,
            .resources = &engine.resources,
        };
    }
};

pub fn SystemManager(
    Systems: []const type,
) type {
    const SystemHook = enum {
        deinit,
        initEntities,
        update,
        drawImgui,
        registerSets,
        updateSets,
        syncResources,
        syncWorld,
        initComputePipelines,
        recordComputeCommands,

        const Signatures = std.EnumMap(@This(), std.builtin.Type.Fn);

        inline fn getSignatures(T: type, is_root_type: bool) Signatures {
            var sigs = Signatures.init(.{});
            for (std.meta.tags(@This())) |t| {
                if (@hasDecl(T, @tagName(t))) {
                    const Fn = @TypeOf(@field(T, @tagName(t)));
                    if (@typeInfo(Fn) != .@"fn") @compileError(std.fmt.comptimePrint(
                        "field '{s}' of '{s}' exists but is not a function",
                        .{ @tagName(t), @typeName(T) },
                    ));

                    const func = @typeInfo(Fn).@"fn";
                    if (is_root_type)
                        switch (t) {
                            .updateSets, .registerSets => sigs.put(t, removeSelf(func)),
                            else => sigs.put(t, normalizeSelf(func)),
                        }
                    else switch (t) {
                        .updateSets, .registerSets => sigs.put(t, func),
                        else => sigs.put(t, normalizeSelf(func)),
                    }
                }
            }
            return sigs;
        }
    };

    const SystemType: struct { tag: type, plexe: type } = blk: {
        var names: [Systems.len][]const u8 = undefined;
        var values: [Systems.len]u32 = undefined;
        var types: [Systems.len]type = undefined;
        for (Systems, 0..) |T, i| {
            names[i] = shortTypeName(@typeName(T));
            values[i] = @intCast(i);
            types[i] = ?T;
        }

        break :blk .{
            .tag = @Enum(u32, .exhaustive, &names, &values),
            .plexe = @Struct(
                .auto,
                null,
                &names,
                &types,
                &@splat(.{}),
            ),
        };
    };

    const Manager = struct {
        pub const SystemPlexe = SystemType.plexe;
        pub const SystemTag = SystemType.tag;

        inline fn defaultPlexe() SystemPlexe {
            var self: SystemPlexe = undefined;
            for (std.meta.fields(SystemPlexe)) |f| {
                @field(self, f.name) = null;
            }
            return self;
        }

        const SYSTEM_TYPES: std.EnumArray(SystemTag, type) = blk: {
            var arr: std.EnumArray(SystemType.tag, type) = undefined;
            for (Systems, 0..) |T, i| {
                arr.set(@enumFromInt(i), T);
            }
            break :blk arr;
        };

        const SystemHooks = std.EnumArray(SystemTag, SystemHook.Signatures);

        const SIGNATURES = SystemHook.getSignatures(@This(), true);

        comptime {
            @setEvalBranchQuota(100_000);
            if (SIGNATURES.bits.mask !=
                std.StaticBitSet(std.enums.values(SystemHook).len).full.mask)
            {
                var missing: []const u8 = "";
                for (std.meta.tags(SystemHook)) |tag| {
                    if (!SIGNATURES.contains(tag)) {
                        missing = missing ++ (if (missing.len == 0) "" else ", ") ++ @tagName(tag);
                    }
                }
                @compileError(std.fmt.comptimePrint(
                    "Manager type must implement all functions declared in SystemHook, missing: {s}",
                    .{missing},
                ));
            }

            for (std.meta.tags(SystemTag)) |tag| {
                const T = SYSTEM_TYPES.get(tag);
                var sigs = SystemHook.getSignatures(T, false);

                var present: []const u8 = "";
                for (std.meta.tags(SystemHook)) |hook| {
                    if (sigs.contains(hook)) {
                        present = present ++ (if (present.len == 0) "" else ", ") ++ @tagName(hook);
                    }
                }
                // PLEASE DONT REMOVE
                // @compileLog(std.fmt.comptimePrint("{s}: [{s}]", .{ @typeName(T), present }));

                var iter = sigs.iterator();
                while (iter.next()) |v| {
                    const myFunc = SIGNATURES.get(v.key).?;
                    if (!fnEql(myFunc, v.value.*)) @compileError(
                        std.fmt.comptimePrint(
                            \\ type '{s}' has an incorrect '{s}' function declaration.
                            \\ expected: {s}
                            \\ got:      {s}
                        , .{
                            @typeName(T),
                            @tagName(v.key),
                            formatFnSig(myFunc),
                            formatFnSig(v.value.*),
                        }),
                    );
                }
            }
        }

        pub fn addSystem(self: *@This(), comptime which: SystemTag, sys: SYSTEM_TYPES.get(which)) void {
            @field(self.plexe, @tagName(which)) = sys;
        }

        plexe: SystemPlexe = defaultPlexe(),

        pub fn updateSets(
            self: @This(),
            device: vk.Device,
            allocated_resources: *core.resources.Manager.AllocatedData,
        ) void {
            inline for (0..@typeInfo(SystemTag).@"enum".fields.len) |i| {
                const tag: SystemTag = @enumFromInt(i);
                if (@hasDecl(SYSTEM_TYPES.get(tag), @src().fn_name)) {
                    if (@field(self.plexe, @tagName(tag)) != null)
                        SYSTEM_TYPES.get(tag).updateSets(device, allocated_resources);
                }
            }
        }

        pub fn registerSets(
            self: @This(),
            a: std.mem.Allocator,
            device: vk.Device,
            resources: *core.resources.Manager,
            alloc_cbs: ?*vk.AllocationCallbacks,
        ) std.mem.Allocator.Error!void {
            inline for (0..@typeInfo(SystemTag).@"enum".fields.len) |i| {
                const tag: SystemTag = @enumFromInt(i);
                if (@hasDecl(SYSTEM_TYPES.get(tag), @src().fn_name))
                    if (@field(self.plexe, @tagName(tag)) != null)
                        try SYSTEM_TYPES.get(tag).registerSets(a, device, resources, alloc_cbs);
            }
        }

        pub fn deinit(
            self: *@This(),
            allocs: core.engine.Allocators,
            device: vk.Device,
            alloc_cbs: ?*vk.AllocationCallbacks,
        ) void {
            inline for (0..@typeInfo(SystemTag).@"enum".fields.len) |i| {
                const tag: SystemTag = @enumFromInt(i);
                if (@hasDecl(SYSTEM_TYPES.get(tag), @src().fn_name))
                    if (@field(self.plexe, @tagName(tag))) |*f| f.deinit(allocs, device, alloc_cbs);
            }
        }

        pub fn initEntities(
            self: *@This(),
            world: *core.engine.world.GameWorld,
            resources: *const core.resources.Manager,
        ) std.mem.Allocator.Error!void {
            inline for (0..@typeInfo(SystemTag).@"enum".fields.len) |i| {
                const tag: SystemTag = @enumFromInt(i);
                if (@hasDecl(SYSTEM_TYPES.get(tag), @src().fn_name))
                    if (@field(self.plexe, @tagName(tag))) |*f| try f.initEntities(world, resources);
            }
        }

        pub fn update(
            self: *@This(),
            dt: f32,
            input: core.engine.Input,
            world: *core.engine.world.GameWorld,
        ) void {
            inline for (0..@typeInfo(SystemTag).@"enum".fields.len) |i| {
                const tag: SystemTag = @enumFromInt(i);
                if (@hasDecl(SYSTEM_TYPES.get(tag), @src().fn_name))
                    if (@field(self.plexe, @tagName(tag))) |*f| f.update(dt, input, world);
            }
        }

        pub fn drawImgui(self: *@This(), ctx: DrawImguiContext) void {
            inline for (0..@typeInfo(SystemTag).@"enum".fields.len) |i| {
                const tag: SystemTag = @enumFromInt(i);
                if (@hasDecl(SYSTEM_TYPES.get(tag), @src().fn_name))
                    if (@field(self.plexe, @tagName(tag))) |*f| f.drawImgui(ctx);
            }
        }

        pub fn syncResources(
            self: *@This(),
            allocated_resources: core.resources.Manager.AllocatedData,
        ) void {
            inline for (0..@typeInfo(SystemTag).@"enum".fields.len) |i| {
                const tag: SystemTag = @enumFromInt(i);
                if (@hasDecl(SYSTEM_TYPES.get(tag), @src().fn_name))
                    if (@field(self.plexe, @tagName(tag))) |*f| f.syncResources(allocated_resources);
            }
        }

        /// This function should not mutate world
        /// unfortunately the implementation requires a non const *
        /// to World in order to do anything
        /// this might need to be changed in the future to enforce *const access
        ///
        /// This function takes an allocator but it is called in the
        /// hot loop, allocations should be as conservative as possible
        pub fn syncWorld(
            self: *@This(),
            a: std.mem.Allocator,
            world: *core.engine.world.GameWorld,
        ) std.mem.Allocator.Error!void {
            inline for (0..@typeInfo(SystemTag).@"enum".fields.len) |i| {
                const tag: SystemTag = @enumFromInt(i);
                if (@hasDecl(SYSTEM_TYPES.get(tag), @src().fn_name))
                    if (@field(self.plexe, @tagName(tag))) |*f| try f.syncWorld(a, world);
            }
        }

        pub fn initComputePipelines(
            self: *@This(),
            device: vk.Device,
            resources: core.resources.Manager,
            alloc_cbs: ?*vk.AllocationCallbacks,
        ) void {
            inline for (0..@typeInfo(SystemTag).@"enum".fields.len) |i| {
                const tag: SystemTag = @enumFromInt(i);
                if (@hasDecl(SYSTEM_TYPES.get(tag), @src().fn_name))
                    if (@field(self.plexe, @tagName(tag))) |*f| f.initComputePipelines(device, resources, alloc_cbs);
            }
        }

        pub fn recordComputeCommands(
            self: @This(),
            allocated_resources: core.resources.Manager.AllocatedData,
            swapchain: core.bindings.vulkan_init.Swapchain,
            cmd: vk.CommandBuffer,
            framebuffer_idx: u32,
        ) void {
            inline for (0..@typeInfo(SystemTag).@"enum".fields.len) |i| {
                const tag: SystemTag = @enumFromInt(i);
                if (@hasDecl(SYSTEM_TYPES.get(tag), @src().fn_name))
                    if (@field(self.plexe, @tagName(tag))) |*f| f.recordComputeCommands(
                        allocated_resources,
                        swapchain,
                        cmd,
                        framebuffer_idx,
                    );
            }
        }
    };

    return Manager;
}
