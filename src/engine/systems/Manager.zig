const std = @import("std");
const core = @import("../../root.zig");
const log = std.log.scoped(.SystemManager);
const vk = core.clibs.vk;
// pub const MeshManipulation = @import("./MeshManipulation.zig");
pub const Maze = @import("./Maze.zig");
pub const Debug = @import("./Debug.zig");
pub const PhysicsDebug = @import("./PhysicsDebug.zig");
pub const Camera = @import("./Camera.zig");
pub const DrawBackground = @import("./DrawBackground.zig");

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
inline fn normalizeFn(fn_info: std.builtin.Type.Fn) std.builtin.Type.Fn {
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

pub fn NewSystem(
    Systems: []const type,
) type {
    const SystemHook = enum {
        deinit,
        update,
        drawImgui,
        recordComputeCommands,
        registerSets,
        updateSets,
        initPipelines,
        trySyncResources,
        // recordGraphicsCommands,

        const Signatures = std.EnumMap(@This(), std.builtin.Type.Fn);

        inline fn getSignatures(T: type) Signatures {
            var sigs = Signatures.init(.{});
            for (std.meta.tags(@This())) |t| {
                if (@hasDecl(T, @tagName(t))) {
                    const Fn = @TypeOf(@field(T, @tagName(t)));
                    if (@typeInfo(Fn) != .@"fn") @compileError(std.fmt.comptimePrint(
                        "field '{s}' of '{s}' exists but is not a function",
                        .{ @tagName(t), @typeName(T) },
                    ));
                    sigs.put(t, normalizeFn(@typeInfo(Fn).@"fn"));
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
            types[i] = T;
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

        const SYSTEM_TYPES: std.EnumArray(SystemTag, type) = blk: {
            var arr: std.EnumArray(SystemType.tag, type) = undefined;
            for (Systems, 0..) |T, i| {
                arr.set(@enumFromInt(i), T);
            }
            break :blk arr;
        };

        const SystemHooks = std.EnumArray(SystemTag, SystemHook.Signatures);

        const SIGNATURES = SystemHook.getSignatures(@This());

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
                var sigs = SystemHook.getSignatures(T);

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
                    if (!std.meta.eql(myFunc, v.value.*)) @compileError(
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

        plexe: SystemPlexe,

        pub fn init(plexe: SystemPlexe) @This() {
            return .{
                .plexe = plexe,
            };
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
                    @field(self.plexe, @tagName(tag)).deinit(allocs, device, alloc_cbs);
            }
        }

        pub fn update(self: *@This(), engine: *core.engine.Engine) void {
            inline for (0..@typeInfo(SystemTag).@"enum".fields.len) |i| {
                const tag: SystemTag = @enumFromInt(i);
                if (@hasDecl(SYSTEM_TYPES.get(tag), @src().fn_name))
                    @field(self.plexe, @tagName(tag)).update(engine);
            }
        }

        pub fn drawImgui(self: *@This(), engine: *core.engine.Engine) void {
            inline for (0..@typeInfo(SystemTag).@"enum".fields.len) |i| {
                const tag: SystemTag = @enumFromInt(i);
                if (@hasDecl(SYSTEM_TYPES.get(tag), @src().fn_name))
                    @field(self.plexe, @tagName(tag)).drawImgui(engine);
            }
        }

        pub fn registerSets(
            a: std.mem.Allocator,
            device: vk.Device,
            resources: *core.resources.Manager,
            alloc_cbs: ?*vk.AllocationCallbacks,
        ) std.mem.Allocator.Error!void {
            inline for (0..@typeInfo(SystemTag).@"enum".fields.len) |i| {
                const tag: SystemTag = @enumFromInt(i);
                if (@hasDecl(SYSTEM_TYPES.get(tag), @src().fn_name))
                    try SYSTEM_TYPES.get(tag).registerSets(a, device, resources, alloc_cbs);
            }
        }

        pub fn trySyncResources(
            self: *@This(),
            allocated_resources: core.resources.Manager.AllocatedData,
        ) void {
            inline for (0..@typeInfo(SystemTag).@"enum".fields.len) |i| {
                const tag: SystemTag = @enumFromInt(i);
                if (@hasDecl(SYSTEM_TYPES.get(tag), @src().fn_name))
                    @field(self.plexe, @tagName(tag)).trySyncResources(allocated_resources);
            }
        }

        pub fn initPipelines(
            self: *@This(),
            device: vk.Device,
            resources: core.resources.Manager,
            alloc_cbs: ?*vk.AllocationCallbacks,
        ) void {
            inline for (0..@typeInfo(SystemTag).@"enum".fields.len) |i| {
                const tag: SystemTag = @enumFromInt(i);
                if (@hasDecl(SYSTEM_TYPES.get(tag), @src().fn_name))
                    @field(self.plexe, @tagName(tag)).initPipelines(device, resources, alloc_cbs);
            }
        }

        pub fn updateSets(
            device: vk.Device,
            allocated_resources: *core.resources.Manager.AllocatedData,
        ) void {
            inline for (0..@typeInfo(SystemTag).@"enum".fields.len) |i| {
                const tag: SystemTag = @enumFromInt(i);
                if (@hasDecl(SYSTEM_TYPES.get(tag), @src().fn_name))
                    SYSTEM_TYPES.get(tag).updateSets(device, allocated_resources);
            }
        }

        pub fn recordComputeCommands(
            self: @This(),
            engine: core.engine.Engine,
            cmd: vk.CommandBuffer,
            framebuffer_idx: u32,
        ) void {
            inline for (0..@typeInfo(SystemTag).@"enum".fields.len) |i| {
                const tag: SystemTag = @enumFromInt(i);
                if (@hasDecl(SYSTEM_TYPES.get(tag), @src().fn_name))
                    @field(self.plexe, @tagName(tag)).recordComputeCommands(engine, cmd, framebuffer_idx);
            }
        }
    };

    return Manager;
}

test "NewSystem dispatches only implemented hooks" {
    const TestSystemA = struct {
        deinit_called: bool = false,

        pub fn deinit(
            self: *@This(),
            allocs: core.engine.Allocators,
            device: vk.Device,
            alloc_cbs: ?*vk.AllocationCallbacks,
        ) void {
            _ = allocs;
            _ = device;
            _ = alloc_cbs;
            self.deinit_called = true;
        }
    };

    const TestSystemB = struct {
        deinit_called: bool = false,
        graphics_called: bool = false,

        pub fn deinit(
            self: *@This(),
            allocs: core.engine.Allocators,
            device: vk.Device,
            alloc_cbs: ?*vk.AllocationCallbacks,
        ) void {
            _ = allocs;
            _ = device;
            _ = alloc_cbs;
            self.deinit_called = true;
        }

        pub fn recordGraphicsCommands(self: *@This(), cmd: vk.CommandBuffer) void {
            _ = cmd;
            self.graphics_called = true;
        }
    };
    const Manager = NewSystem(&.{ TestSystemA, TestSystemB });

    var manager = Manager.init(.{
        .TestSystemA = .{},
        .TestSystemB = .{},
    });

    // TestSystemA has no recordGraphicsCommands — must be a silent no-op for it,
    // while still reaching TestSystemB's implementation.
    // manager.recordGraphicsCommands(undefined);
    // try std.testing.expect(manager.plexe.TestSystemB.graphics_called);

    manager.deinit(undefined, undefined, null);
    try std.testing.expect(manager.plexe.TestSystemA.deinit_called);
    try std.testing.expect(manager.plexe.TestSystemB.deinit_called);
}

maze: Maze,
camera: Camera,
draw_background: DrawBackground,
debug: Debug,
physics_debug: PhysicsDebug,

pub fn init(
    a: std.mem.Allocator,
    world: *core.engine.world.GameWorld,
    resources: *core.resources.Manager,
    swapchain_extent: vk.Extent2D,
    maze_system_ci: core.engine.systems.Maze.CreateInfo,
) std.mem.Allocator.Error!@This() {
    return .{
        // .mesh_manipulation = .{},
        .maze = try Maze.init(a, world, resources, maze_system_ci),
        .debug = .{},
        .camera = try Camera.init(a, resources, world, .{}, swapchain_extent),
        .draw_background = try DrawBackground.init(a, resources, swapchain_extent),
        .physics_debug = PhysicsDebug{},
    };
}

pub fn deinit(
    self: *@This(),
    allocs: core.engine.Allocators,
    device: vk.Device,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    self.maze.deinit(allocs.std, device, alloc_cbs);
    self.debug.deinit(allocs.std);
    self.draw_background.deinit(device, alloc_cbs);
    self.physics_debug.deinit(allocs.std, device, alloc_cbs);
}

pub fn registerSets(
    _: @This(),
    a: std.mem.Allocator,
    device: vk.Device,
    resources: *core.resources.Manager,
    alloc_cbs: ?*vk.AllocationCallbacks,
) std.mem.Allocator.Error!void {
    try Maze.registerSets(a, device, resources, alloc_cbs);
    try Camera.registerSets(a, device, resources, alloc_cbs);
    try DrawBackground.registerSets(a, device, resources, alloc_cbs);
}

pub fn updateSets(
    _: @This(),
    device: vk.Device,
    allocated_resources: *core.resources.Manager.AllocatedData,
) void {
    allocated_resources.mapped_buffers.updateBufferSet(
        device,
        Camera.CAMERA_SET_NAME,
    );

    allocated_resources.mapped_buffers.updateBufferSet(
        device,
        core.engine.graphics_pipelines.Mesh3DPipeline.RenderSystem.INSTANCE_SET_NAME,
    );

    allocated_resources.mapped_buffers.updateBufferSet(
        device,
        Maze.COMPUTE_MAZE_SET_NAME,
    );

    allocated_resources.materials.updateWritableTextureSet(
        device,
        Maze.COMPUTE_MAZE_SET_NAME,
    );

    allocated_resources.materials.updateWritableTextureSet(
        device,
        DrawBackground.BACKGROUND_SET_NAME,
    );
}
/// wasnt sure what to call this
/// currently only Debug has a need for access to
/// resources after they are created but im sure this
/// will change
pub fn bind(
    self: *@This(),
    a: std.mem.Allocator,
    resources: core.resources.Manager,
    alloc_resources: core.resources.Manager.AllocatedData,
) void {
    self.debug.bind(a, resources, alloc_resources) catch @panic("OOM");
}

pub fn update(self: *@This(), engine: *core.engine.Engine) void {
    self.camera.update(engine);
    self.maze.update();
    // self.physics.update(&engine.world);
}

pub fn initPipelines(
    self: *@This(),
    device: vk.Device,
    resources: core.resources.Manager,
    alloc_cbs: ?*vk.AllocationCallbacks,
) void {
    self.maze.initPipeline(resources, alloc_cbs);
    self.draw_background.initPipeline(device, resources, alloc_cbs);
    // self.physics_debug.initPipeline(device, resources, alloc_cbs);
}

pub fn trySyncResources(
    self: *@This(),
    _: core.resources.Manager,
    allocated_resources: core.resources.Manager.AllocatedData,
    _: *core.engine.world.GameWorld,
) void {
    self.maze.trySyncResources(allocated_resources);
    // self.mesh_manipulation.trySyncResources(resources, allocated_resources, world);
    self.camera.trySyncResources(allocated_resources);
}

pub fn drawImgui(self: *@This(), engine: *core.engine.Engine) void {
    self.debug.drawImgui(engine.window);
    self.camera.drawImgui(engine);
    self.draw_background.drawImgui();
    self.maze.drawImgui();
    // self.mesh_manipulation.drawImgui(
    //     engine.allocs.std,
    //     &engine.mesh3D_pipeline,
    //     &engine.world,
    //     engine.resources,
    //     engine.allocated_resources,
    // );
}

pub fn recordComputeCommands(
    self: @This(),
    engine: core.engine.Engine,
    cmd: vk.CommandBuffer,
    framebuffer_idx: u32,
) void {
    self.maze.pipeline.bind(cmd);
    self.maze.pipeline.recordCommands(
        engine.allocated_resources,
        engine.allocated_resources.mapped_buffers.buffer_sets.get(Camera.CAMERA_SET_NAME).?.set,
        engine.allocated_resources.materials.writable_textures_descriptor_sets.get(Maze.COMPUTE_MAZE_SET_NAME).?.set,
        engine.allocated_resources.mapped_buffers.buffer_sets.get(Maze.COMPUTE_MAZE_SET_NAME).?.set,
        self.maze,
        cmd,
    );

    self.draw_background.pipeline.bind(cmd);
    self.draw_background.pipeline.recordCommands(
        engine.allocated_resources,
        engine.swapchain,
        framebuffer_idx,
        engine.allocated_resources.materials.writable_textures_descriptor_sets.get(DrawBackground.BACKGROUND_SET_NAME).?.set,
        cmd,
    );
}
