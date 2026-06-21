const rl = @import("raylib");
const std = @import("std");
const zbt = @import("zbullet");
const engine = @import("root.zig");
const warn = std.log.warn;
const Type = std.builtin.Type;
const Shape = zbt.Shape;
const Allocator = std.mem.Allocator;

pub fn IdentifierManager(
    comptime T: type,
    MAX: comptime_int,
) type {
    return struct {
        const IdentifierNode = struct {
            node: std.DoublyLinkedList.Node = .{},
            id: u32,
        };
        const IdQueue = std.DoublyLinkedList;
        const Manager = @This();

        available_ids: std.DoublyLinkedList,
        index_map: std.AutoHashMap(u32, usize),
        identifier_map: std.AutoHashMap(usize, *IdentifierNode),
        count: usize,
        /// Maintains a *tightly packed* array of Data
        data: [MAX]?T = blk: {
            var all: [MAX]?T = undefined;
            @memset(&all, null);
            break :blk all;
        },

        /// requires the same allocator be passed as with `init`
        pub fn deinit(self: *@This(), allocator: Allocator) void {
            defer self.index_map.deinit();
            var keys = self.identifier_map.keyIterator();
            while (keys.next()) |k| {
                const kv = self.identifier_map.fetchRemove(k.*) orelse unreachable;
                allocator.destroy(kv.value);
            }
            defer self.identifier_map.deinit();
            while (self.available_ids.pop()) |n|
                allocator.destroy(@as(*IdentifierNode, @fieldParentPtr("node", n)));
        }

        pub fn init(allocator: Allocator) (std.posix.OpenError || Allocator.Error)!Manager {
            var prng = std.Random.DefaultPrng.init(blk: {
                var seed: u64 = undefined;
                try std.posix.getrandom(std.mem.asBytes(&seed));
                break :blk seed;
            });
            const rand = prng.random();

            var available_ids = std.DoublyLinkedList{};

            for (0..MAX) |_| {
                const node = try allocator.create(IdentifierNode);
                node.* = .{
                    .id = rand.int(u32),
                };
                available_ids.append(&node.node);
            }

            const idx_map = std.AutoHashMap(u32, usize).init(allocator);
            const ent_map = std.AutoHashMap(usize, *IdentifierNode).init(allocator);
            return Manager{
                .available_ids = available_ids,
                .index_map = idx_map,
                .identifier_map = ent_map,
                .count = 0,
            };
        }

        /// Returns the identifier & index of registered entity
        pub fn register(
            self: *Manager,
            data: T,
        ) Allocator.Error!struct { u32, usize } {
            const id_node: *IdentifierNode = @fieldParentPtr("node", self.available_ids.pop() orelse @panic("Identifier not available"));
            try self.index_map.put(id_node.id, self.count);
            try self.identifier_map.put(self.count, id_node);
            self.data[self.count] = data;
            self.count += 1;
            return .{ id_node.id, self.count - 1 };
        }

        pub fn lastRegistered(self: Manager) ?struct { u32, usize } {
            const dif = MAX - self.available_ids.len();
            if (dif == 0) return null;
            const idx = dif - 1;
            const node = self.identifier_map.get(idx) orelse return null;
            return .{ node.id, idx };
        }

        pub fn remove(self: *Manager, id: u32) (error{NotPresent} || Allocator.Error)!void {
            const index = (self.index_map.fetchRemove(id) orelse return error.NotPresent).value;
            const node = (self.identifier_map.fetchRemove(index) orelse @panic("No node for index?")).value;
            if (self.lastRegistered()) |last_reg| {
                if (last_reg.@"0" != id) {
                    const last_reg_kv = self.identifier_map.fetchRemove(last_reg.@"1") orelse @panic("No node for last registered?");
                    const last_reg_node = last_reg_kv.value;
                    const last_data = self.getData(last_reg.@"0") orelse @panic("No signature for last registered?");
                    try self.index_map.put(last_reg.@"0", index);
                    try self.identifier_map.put(index, last_reg_node);
                    self.data[index] = last_data;
                    self.data[last_reg.@"1"] = null;
                }
            }

            self.available_ids.append(&node.node);
            self.count -= 1;

            return;
        }

        pub fn getId(self: Manager, idx: usize) ?u32 {
            return (self.identifier_map.get(idx) orelse return null).id;
        }

        pub fn getData(self: Manager, entity: u32) ?T {
            const idx = self.index_map.get(entity) orelse return null;
            return self.data[idx];
        }

        pub fn getDataPtr(self: *Manager, entity: u32) ?*T {
            const idx = self.index_map.get(entity) orelse return null;
            return &(self.data[idx] orelse return null);
        }
    };
}

test "register assigns ids and stores data" {
    const Manager = IdentifierManager(u8, 8);
    var m = try Manager.init(std.testing.allocator);
    defer m.deinit(std.testing.allocator);

    const a = try m.register(10);
    const b = try m.register(20);

    try std.testing.expectEqual(@as(usize, 2), m.count);
    try std.testing.expectEqual(@as(u8, 10), m.getData(a.@"0").?);
    try std.testing.expectEqual(@as(u8, 20), m.getData(b.@"0").?);
}

test "remove decreases count and moves data" {
    const Manager = IdentifierManager(u8, 8);
    var m = try Manager.init(std.testing.allocator);
    defer m.deinit(std.testing.allocator);

    const a = try m.register(1);
    const b = try m.register(2);

    try m.remove(a.@"0");

    try std.testing.expectEqual(@as(usize, 1), m.count);
    try std.testing.expect(m.getData(a.@"0") == null);
    try std.testing.expectEqual(@as(u8, 2), m.getData(b.@"0").?);
}

test "remove middle swaps last into hole" {
    const Manager = IdentifierManager(u8, 8);
    var m = try Manager.init(std.testing.allocator);
    defer m.deinit(std.testing.allocator);

    const a = try m.register(1);
    const b = try m.register(2);
    const c_ = try m.register(3);

    try m.remove(b.@"0");

    try std.testing.expectEqual(@as(usize, 2), m.count);
    try std.testing.expectEqual(@as(u8, 1), m.getData(a.@"0").?);
    try std.testing.expectEqual(@as(u8, 3), m.getData(c_.@"0").?);
}

test "ids are reused after removal" {
    const Manager = IdentifierManager(u8, 4);
    var m = try Manager.init(std.testing.allocator);
    defer m.deinit(std.testing.allocator);

    const a = try m.register(42);
    try m.remove(a.@"0");

    const b = try m.register(99);

    try std.testing.expectEqual(a.@"0", b.@"0");
    try std.testing.expectEqual(@as(u8, 99), m.getData(b.@"0").?);
}

test "lastRegistered returns last live element" {
    const Manager = IdentifierManager(u8, 8);
    var m = try Manager.init(std.testing.allocator);
    defer m.deinit(std.testing.allocator);

    _ = try m.register(1);
    const b = try m.register(2);

    const last = m.lastRegistered() orelse @panic("No last registered?");
    try std.testing.expectEqual(b.@"0", last.@"0");
    try std.testing.expectEqual(@as(usize, 1), last.@"1");
}

test "getDataPtr allows mutation" {
    const Manager = IdentifierManager(u8, 8);
    var m = try Manager.init(std.testing.allocator);
    defer m.deinit(std.testing.allocator);

    const id = try m.register(10);

    const ptr = m.getDataPtr(id.@"0") orelse unreachable;
    ptr.* = 42;

    try std.testing.expectEqual(@as(u8, 42), m.getData(id.@"0").?);
}

test "getDataPtr mutation persists across operations" {
    const Manager = IdentifierManager(u8, 8);
    var m = try Manager.init(std.testing.allocator);
    defer m.deinit(std.testing.allocator);

    const a = try m.register(1);
    const b = try m.register(2);

    const a_ptr = m.getDataPtr(a.@"0") orelse unreachable;
    a_ptr.* = 99;

    // unrelated removal
    try m.remove(b.@"0");

    try std.testing.expectEqual(@as(u8, 99), m.getData(a.@"0").?);
}
pub const ComponentDecl = struct { [:0]const u8, type };
pub const Entity = u32;

pub const EcsOptions = struct {
    max_entities: usize,
    max_systems: usize,
    /// Starting to feel fishy
    State: type,
    // components: []const ComponentDecl,
    /// Components are declared by a simple struct
    components: type,
    // systems: []type,
};

/// Entity Component System "Coordinator"
pub fn Ecs(
    comptime Options: EcsOptions,
) type {
    if (Options.max_entities == 0 or Options.max_systems == 0) {
        @compileError("Set Options.max_entities & Options.max_systems to at least 1!");
    }
    return struct {
        const ThisEcs = @This();
        pub const State = Options.State;
        pub const Opts = Options;
        const N_COMPONENTS: usize =
            @intCast(@typeInfo(Options.components).@"struct".fields.len);
        /// this is an allocator returned by `ArenaAllocator.allocator()`
        allocator: Allocator,
        entities: EntityManager,
        systems: SystemManager,
        components: ComponentsManager,

        pub fn init(arena: *std.heap.ArenaAllocator) ThisEcs {
            const alloc = arena.allocator();
            return ThisEcs{
                .allocator = alloc,
                .entities = EntityManager.init(alloc),
                .systems = SystemManager.init(alloc) catch @panic("FAILED to initialize Systems Manager"),
                .components = ComponentsManager.init(),
            };
        }
        pub fn deinit(self: *ThisEcs) void {
            self.entities.manager.deinit(self.allocator);
            self.systems.deinit();
            self.components.deinit(self.allocator);
        }

        /// Archetypes can easily be expressed through signatures:
        /// ```zig
        /// var archetype = Signature.initZeros();
        /// archetype.set(@intFromEnum(ComponentTag.mycomponent));
        /// archetype.set(@intFromEnum(ComponentTag.othercomponent));
        /// ```
        pub const Signature = std.bit_set.IntegerBitSet(N_COMPONENTS);

        /// If `ECS` finds no enities matching `queries`, the system will not run
        /// If `queries` field is null, the system will run regardless
        pub const System = struct {
            const StartFunc = *const fn (*anyopaque, *ThisEcs) anyerror!void;
            const RunFunc = *const fn (*anyopaque, *ThisEcs, *Options.State) anyerror!void;
            disabled: bool = false,
            // schedule: SysSchedule,
            inner: *anyopaque,
            /// Sometimes a system wants to spawn entities or do other setup
            startupFn: ?StartFunc,
            runFn: RunFunc,

            /// **Requirements** for type passed as `T`:
            ///  `pub fn run(*@This(),  *ThisEcs, *Options.State) anyerror!void`
            ///  Optionally:
            /// `pub fn startup(*@This(), *ThisEcs)  anyerror!void`
            /// **!! NOTE THEY ARE PUBLIC !!**
            /// Allocates for *inner
            /// > INFO Feels weird
            pub fn init(
                allocator: std.mem.Allocator,
                T: type,
                v: T,
            ) Allocator.Error!@This() {
                const inner = try allocator.create(T);
                inner.* = v;
                var startFunc: ?System.StartFunc = null;

                std.log.warn(
                    \\ Initializing {s} system..
                    \\
                , .{@typeName(T)});

                if (std.meta.hasFn(T, "startup")) {
                    startFunc = struct {
                        fn start(val: *anyopaque, ecs: *ThisEcs) anyerror!void {
                            std.log.warn(
                                \\ {s} Startup running...
                                \\
                            , .{@typeName(T)});
                            const val_as_type: *T = @ptrCast(@alignCast(val));
                            std.log.warn(
                                \\ VALUE: 
                                \\ {any}
                            , .{val_as_type.*});
                            return T.startup(val_as_type, ecs);
                        }
                    }.start;
                }

                return System{
                    // .schedule = schedule,
                    .inner = @ptrCast(inner),
                    // .alignment = @alignOf(T),
                    .runFn = struct {
                        fn run(val: *anyopaque, ecs: *ThisEcs, state: *Options.State) anyerror!void {
                            std.log.warn(
                                \\ {s} System running...
                                \\
                                \\ alignment: {d}
                                \\ target alignment: {d}
                            , .{ @typeName(T), @alignOf(@TypeOf(val)), @alignOf(T) });
                            const val_as_type: *T = @ptrCast(@alignCast(val));
                            return T.run(val_as_type, ecs, state);
                        }
                    }.run,
                    .startupFn = startFunc,
                };
            }
        };

        /// Maps to fields of system manager.
        /// > this was the quickest way to implement scheduling, I'm sure there's a better way
        pub const SysSchedule = enum {
            pre_render,
            render,
            post_render,
        };

        const SystemManager = struct {
            all: IdentifierManager(System, Options.max_systems),
            schedules: std.AutoHashMap(SysSchedule, std.AutoHashMap(u32, void)),
            fn init(allocator: Allocator) !@This() {
                return .{
                    .all = try IdentifierManager(System, Options.max_systems).init(allocator),
                    .schedules = std.AutoHashMap(SysSchedule, std.AutoHashMap(u32, void)).init(allocator),
                };
            }
            fn deinit(self: *@This()) void {
                defer self.schedules.deinit();
                var iter =
                    self.schedules.iterator();
                while (iter.next()) |entry| {
                    entry.value_ptr.*.deinit();
                }
            }
        };

        pub fn registerSystem(self: *@This(), system: System, schedule: SysSchedule) Allocator.Error!struct { u32, usize } {
            const registered = try self.systems.all.register(system);
            const result = try self.systems.schedules.getOrPut(schedule);

            if (!result.found_existing) {
                var set = std.AutoHashMap(u32, void).init(self.allocator);
                try set.put(registered.@"0", {});
                result.value_ptr.* = set;
            } else {
                try result.value_ptr.*.put(registered.@"0", {});
            }
            return registered;
        }

        /// nullifies startFn after running
        /// This is maybe a bad solution to keeping track of systems that have been started
        /// > but also maybe very good?
        pub fn startSytem(self: *ThisEcs, sys_id: u32) anyerror!void {
            var system = self.systems.all.getData(sys_id) orelse return error.NoData;
            const func = system.startupFn orelse return;

            std.log.warn(
                \\ starting System with id {d}
                \\ 
            , .{sys_id});
            try func(system.inner, self);
            system.startupFn = null;
        }
        /// Should be run right when drawing mode begins, before the update loop
        /// should take schedule into account
        /// might create entities
        pub fn startSytems(self: *ThisEcs) anyerror!void {
            std.log.warn(
                \\ Starting {d} systems...
                \\
            , .{self.systems.all.count});
            var iter =
                self.systems.all.identifier_map.valueIterator();
            while (iter.next()) |id| {
                try self.startSytem(id.*);
            }
        }

        pub fn runSystems(self: *ThisEcs, state: *ThisEcs.State) anyerror!void {
            for (&[_]SysSchedule{
                .pre_render,
                .render,
                .post_render,
            }) |schedule| {
                const schedule_set =
                    self.systems.schedules.get(schedule);
                if (schedule_set) |set| {
                    var sys_id_iter = set.keyIterator();
                    while (sys_id_iter.next()) |id| {
                        const system = self.systems.all.getData(id.*) orelse return error.NoData;
                        if (system.disabled) continue;
                        try system.runFn(system.inner, self, state);
                    }
                }
            }
        }

        pub fn entityHandle(self: *ThisEcs, entity: Entity) error{NoData}!EntityHandle {
            var sig =
                self.entities.manager.getData(entity) orelse return error.NoData;
            return EntityHandle{ .ecs = self, .identifier = entity, .signature = &sig };
        }
        /// Returns the signature associated with the given component
        pub fn componentSignature(tag: ComponentTag) Signature {
            var sig = Signature.initEmpty();
            sig.set(@intFromEnum(tag));
            return sig;
        }
        /// Returns the signature associated with the given component
        pub fn componentsSignature(tags: []ComponentTag) Signature {
            var sig = Signature.initEmpty();
            for (tags) |c| {
                sig.set(@intFromEnum(c));
            }
            return sig;
        }

        /// Returns the signature associated with the given components
        // pub inline fn signatureComponents(signature: Signature) []ComponentTag {
        //     var all: [N_COMPONENTS]ComponentTag = undefined;
        //     var amt: usize = 0;
        //     for (0..Signature.bit_length, &all) |i, *tag| {
        //         if (signature.isSet(i)) {
        //             tag.* = @intFromEnum(i);
        //             amt += 1;
        //         }
        //     }
        //     return &all;
        // }
        pub inline fn componentType(variant: ComponentTag) type {
            const idx = @intFromEnum(variant);
            return @typeInfo(Options.components).@"struct".fields[idx].type;
        }

        pub fn queryEntities(self: *ThisEcs, query: Query) (error{NoData} || Allocator.Error)!?QueryResult {
            std.log.warn(
                \\
                \\ Running Query {any}
                \\
            , .{query});

            var all = try std.ArrayList(ThisEcs.EntityHandle).initCapacity(self.allocator, 2048);
            // First, we get a result based purely on which type/tag the entity matches
            get_entities: {
                switch (query) {
                    .id => |entity| {
                        std.log.warn(
                            \\ ALL ENTITIES:
                            \\ {any}
                        , .{self.entities.manager.lastRegistered()});
                        if (self.entities.manager.index_map.get(entity)) |_| {
                            try all.append(self.allocator, try self.entityHandle(entity));
                            break :get_entities;
                        }

                        std.log.warn(
                            \\
                            \\ DIRECT QUERY RETURNED NO ENTITY FOR ID: {d}
                        , .{entity});
                        break :get_entities;
                    },
                    .query => |q| {
                        var entity_iter = self.entities.manager.identifier_map.valueIterator();
                        while (entity_iter.next()) |entity| {
                            const idx = self.entities.manager.index_map.get(entity.*.id) orelse @panic("NO INDEX FOR ENTITY??");
                            const sig = self.entities.manager.data[idx] orelse @panic("NO SIGNATURE FOR ENTITY??");

                            var is_match = true;
                            if (q.is) |is|
                                is_match = is.rule.cmpFn()(sig, is.sig);

                            var is_not_match = false;
                            if (q.is_not) |is_not|
                                is_not_match = is_not.rule.cmpFn()(sig, is_not.sig);

                            if (is_match and !is_not_match)
                                try all.append(self.allocator, try self.entityHandle(entity.*.id));
                        }
                        if (all.items.len > 0)
                            break :get_entities;
                    },
                }
            }

            if (all.items.len == 0)
                return null;

            switch (query) {
                .id => {
                    std.debug.assert(all.items.len <= 1);
                    return QueryResult{ .id = try self.entityHandle(query.id) };
                },
                .query => return QueryResult{ .query = try all.toOwnedSlice(self.allocator) },
            }
        }

        pub const QueryRule = enum {
            /// Signature must match EXACTLY the passed components
            exact,
            /// Signature must have AT LEAST the passed components
            at_least,
            /// Signature must have ANY of the passed components, fails if NONE match
            any,

            /// Some function for comparing one signature to another, returns true if the first signature passes the needed requirements
            const ComparisonFunction = *const fn (Signature, Signature) bool;
            pub fn cmpFn(rule: QueryRule) ComparisonFunction {
                return switch (rule) {
                    .at_least => struct {
                        fn cmp(sig: Signature, other: Signature) bool {
                            return sig.supersetOf(other);
                        }
                    }.cmp,
                    .exact => struct {
                        fn cmp(sig: Signature, other: Signature) bool {
                            return sig.eql(other);
                        }
                    }.cmp,
                    .any => struct {
                        fn cmp(sig: Signature, other: Signature) bool {
                            return !sig.intersectWith(other).eql(Signature.initEmpty());
                        }
                    }.cmp,
                };
            }
        };

        pub const QueryStatement = struct {
            rule: QueryRule,
            sig: Signature,
            // component_rules: ?[]const ComponentRule = null,
            pub fn new(rule: QueryRule, components: []const ComponentTag) @This() {
                return .{ .rule = rule, .sig = componentsSignature(@constCast(components)) };
            }
        };

        /// Query can either directly look for an entity by id (id)
        /// or they can be queried by component signature (query)
        pub const QueryType = enum { id, query };
        pub const Query = union(QueryType) {
            id: Entity,
            query: struct {
                is: ?QueryStatement = null,
                is_not: ?QueryStatement = null,
            },
        };

        pub const QueryResult = union(QueryType) { id: ThisEcs.EntityHandle, query: []ThisEcs.EntityHandle };

        const en_info = blk: {
            var fnms: [N_COMPONENTS][]const u8 = undefined;
            var fvls: [N_COMPONENTS]u32 = undefined;
            for (0.., @typeInfo(Options.components).@"struct".fields, &fnms, &fvls) |i, field, *fnm, *fvl| {
                fnm.* = field.name;
                fvl.* = i;
            }
            break :blk .{ fnms, fvls };
        };

        const strct_info = blk: {
            var fnms: [N_COMPONENTS][]const u8 = undefined;
            var ftyps: [N_COMPONENTS]Type = undefined;
            var fattrs: [N_COMPONENTS]std.builtin.Type.StructField.Attributes = undefined;
            for (@typeInfo(Options.components).@"struct".fields, &fnms, &ftyps, &fattrs) |field, *fnm, *ftp, *attr| {
                fnm.* = field.name;
                ftp.* = field.type;
                attr.* = .{};
            }
            break :blk .{ fnms, ftyps, fattrs };
        };
        // const meta_structure: struct { [N_COMPONENTS]Type.EnumField, [N_COMPONENTS]Type.StructField, [N_COMPONENTS]type } = blk: {
        //     var en_fields: [N_COMPONENTS]Type.EnumField = undefined;
        //     var st_fields: [N_COMPONENTS]Type.StructField = undefined;
        //     var types: [N_COMPONENTS]type = undefined;

        //     for (0.., @typeInfo(Options.components).@"struct".fields, &types, &en_fields, &st_fields) |i, field, *t, *enfld, *stfld| {
        //         enfld.* = Type.EnumField{
        //             .name = field.name,
        //             .value = i,
        //         };
        //         stfld.* = Type.StructField{
        //             .name = field.name,
        //             .type = field.type,
        //             .default_value_ptr = null,
        //             .is_comptime = false,
        //             .alignment = @alignOf(field.type),
        //         };
        //         t.* = field.type;
        //     }
        //     break :blk .{ en_fields, st_fields, types };
        // };

        pub const ComponentTag =
            @Enum(u32, .exhaustive, en_info.@"0", en_info.@"1");
        // @Enum(comptime TagInt: type, comptime mode: Type.Enum.Mode, comptime field_names: []const []const u8, comptime field_values: *const [field_names.len]TagInt)
        // @Type(Type{ .@"enum" = .{
        //     .tag_type = u32,
        //     .fields = &meta_structure.@"0",
        //     .decls = &[_]Type.Declaration{},
        //     .is_exhaustive = true,
        // } });
        pub const ComponentPlexe =
            @Struct(.auto, null, strct_info.@"0", strct_info.@"1", strct_info.@"2");
        pub const TypeArr = strct_info.@"1";

        const ComponentsManager = struct {
            arrays: [N_COMPONENTS][Options.max_entities]?*anyopaque,
            pub const Error = error{ InvalidType, OutOfMemory };

            inline fn tagType(which: ComponentTag) type {
                return TypeArr[@intFromEnum(which)];
            }
            pub fn init() @This() {
                return @This(){ .arrays = arr: {
                    var arr: [N_COMPONENTS][Options.max_entities]?*anyopaque = undefined;
                    @memset(&arr, inner: {
                        var a: [Options.max_entities]?*anyopaque = undefined;
                        @memset(&a, null);
                        break :inner a;
                    });
                    break :arr arr;
                } };
            }

            /// **Must** be called with allocator used to insert values
            pub fn deinit(
                self: @This(),
                allocator: Allocator,
            ) void {
                inline for (self.arrays, 0..) |subarr, i| {
                    for (subarr) |opt| {
                        if (opt) |v| {
                            const typed = @as(*TypeArr[i], @ptrCast(@alignCast(v)));
                            allocator.destroy(typed);
                        }
                    }
                }
            }

            /// expects to be passed `T` for `component`
            /// **NEVER** use multiple allocators for a single instance
            pub fn insert(self: *@This(), allocator: Allocator, which: ComponentTag, idx: usize, component: anytype) Error!void {
                switch (@typeInfo(@TypeOf(component))) {
                    .pointer => {
                        std.log.err(
                            \\ Cannot Pass Pointer types to this function
                            \\
                        , .{});
                        return error.InvalidType;
                    },
                    else => {},
                }
                inline for (TypeArr, 0..) |T, i| {
                    if (i == @intFromEnum(which) and @TypeOf(component) == T) {
                        const val_ptr = try allocator.create(T);
                        val_ptr.* = component;
                        self.arrays[@intFromEnum(which)][idx] = val_ptr;
                        return;
                    }
                }
                return error.InvalidType;
            }

            /// moves component at `idx` to `to_idx`
            /// Nullifies data that was previously at `to_idx`
            fn swap(self: *@This(), which: ComponentTag, idx: usize, to_idx: usize) void {
                var arr = self.arrays[@intFromEnum(which)];
                const tmp = arr[idx];
                arr[to_idx] = tmp;
                arr[idx] = null;
                self.arrays[@intFromEnum(which)] = arr;
            }

            pub fn removeNoReturn(self: *@This(), which: ComponentTag, idx: usize) void {
                self.arrays[@intFromEnum(which)][idx] = null;
                return;
            }

            pub fn removeWithReturn(self: *@This(), T: type, which: ComponentTag, idx: usize) ?*T {
                const val = self.arrays[@intFromEnum(which)][idx];
                self.removeNoReturn(which, idx);
                return @ptrCast(@alignCast(val));
            }

            pub fn access(self: *@This(), T: type, which: ComponentTag, idx: usize) ?*T {
                const ptr = self.arrays[@intFromEnum(which)][idx] orelse return null;
                if (@intFromPtr(ptr) % @alignOf(T) != 0) {
                    @panic("Misaligned pointer access in ECS component store");
                }
                return @ptrCast(@alignCast(ptr));
            }
        };

        /// Returns the function by which `Entity`s are compared according to a `Query`'s rule
        /// Helper struct for easily managing any components associated with an entity
        pub const EntityHandle = struct {
            ecs: *ThisEcs,
            identifier: Entity,
            signature: *Signature,

            /// Is `null` if the entity has been removed
            /// This is a little weird, I feel like the handle should be invalidated if index doesn't exist somehow
            /// In other words, a state where this returns `null` should ideally be impossible
            pub fn index(self: @This()) ?usize {
                return self.ecs.entities.manager.index_map.get(self.identifier);
            }

            /// Maybe not the best name?
            /// Removes this entity from the ecs
            /// moves component data to match up indices of the outer components array with the index of the entity
            pub fn destroy(self: @This()) (error{NotPresent} || Allocator.Error)!void {
                const idx = self.index() orelse @panic("EntityHandle has no index?");
                // Before removing the entity, we clear it's component data
                {
                    const sig = self.ecs.entities.manager.getData(self.identifier) orelse @panic("No entity signature?");
                    var bit_idx_iter = sig.iterator(.{});
                    while (bit_idx_iter.next()) |i| {
                        const comp_enum: ComponentTag = @enumFromInt(i);
                        self.ecs.components.removeNoReturn(comp_enum, idx);
                    }
                }

                const last_registered_opt = self.ecs.entities.manager.lastRegistered();

                try self.ecs.entities.manager.remove(self.identifier);

                // Removing the entity will move the last inserted entity
                // We need to update the component data for this moved entity
                {
                    if (last_registered_opt) |last| {
                        const prev_idx_of_moved_ent = last.@"1";
                        // NOTE:
                        // The index we pass here is the *same* index of the removed entity
                        // because the `remove` method moves the last inserted entity into the index of the removed entity
                        const ent = self.ecs.entities.manager.identifier_map.get(idx) orelse @panic("No identifier at that index?");
                        if (last.@"0" != ent.id) {
                            std.debug.panic(
                                \\ Expected last entity inserted to match gotten entity
                                \\ Expected: {}
                                \\ Got: {}
                            , .{ last.@"0", ent.id });
                        }
                        const sig = self.ecs.entities.manager.getData(ent.id) orelse @panic("No entity signature?");
                        var bit_idx_iter = sig.iterator(.{});
                        while (bit_idx_iter.next()) |i| {
                            const comp_enum: ComponentTag = @enumFromInt(i);
                            self.ecs.components.swap(comp_enum, prev_idx_of_moved_ent, idx);
                        }
                    }
                }
            }

            pub fn removeComponent(self: *@This(), which: ComponentTag, component: anytype) void {
                const idx = self.index() orelse @panic("NO INDEX?");
                var sig = self.ecs.entities.manager.data[idx];
                sig.unset(@intFromEnum(which));
                self.ecs.components.removeNoReturn(@TypeOf(component), which, idx);
            }

            pub fn addComponent(self: *@This(), which: ComponentTag, component: anytype) ComponentsManager.Error!void {
                const idx = self.index() orelse @panic("NO INDEX?");
                var sig = self.ecs.entities.manager.data[idx] orelse @panic("NO DATA?");
                std.log.debug("sig: {b}\n", .{sig.mask});
                sig.set(@intFromEnum(which));
                std.log.debug("changed sig: {b}\n", .{sig.mask});
                self.ecs.entities.manager.data[idx] = sig;
                try self.ecs.components.insert(self.ecs.allocator, which, idx, component);
            }

            pub fn accessComponent(
                self: *@This(),
                T: type,
                which: ComponentTag,
            ) error{AccessFailed}!*T {
                return self.ecs.components.access(
                    T,
                    which,
                    self.index() orelse @panic("EntityHandle has no index?"),
                ) orelse return error.AccessFailed;
            }
        };

        const EntityManager = struct {
            manager: IdentifierManager(Signature, Options.max_entities),

            fn init(allocator: Allocator) @This() {
                return .{ .manager = IdentifierManager(Signature, Options.max_entities).init(allocator) catch @panic("Could not create IdentifierManager for Entities") };
            }

            /// Creates an empty with an empty `Signature`
            pub fn register(self: *@This()) Allocator.Error!EntityHandle {
                const id, const i = try self.manager.register(Signature.initEmpty());
                // _ = i;
                var parent_ptr =
                    @as(*ThisEcs, @fieldParentPtr("entities", self));
                _ = &parent_ptr;

                return EntityHandle{ .ecs = parent_ptr, .identifier = id, .signature = &self.manager.data[i].? };
            }
        };
    };
}

test "ECS Entity Management" {
    std.testing.refAllDecls(@This());
    const allocator = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    std.debug.print(
        \\
        \\ ---INIT ECS TEST---
        \\
    , .{});

    const State = struct {
        pub fn draw() void {}
        pub fn update() void {}
    };
    const MyEcs = Ecs(.{
        .max_entities = 5,
        .max_systems = 5,
        .State = State,
        .components = struct {
            somecomponent: bool,
            othercomponent: u8,
            someothercomponent: u32,
        },
    });
    var ecs = MyEcs.init(&arena);
    defer ecs.deinit();

    // Entity Initialization
    // ---
    const entity_a: MyEcs.EntityHandle = a: {
        var handle = try ecs.entities.register();
        const someother: u32 = 5;
        try handle.addComponent(.someothercomponent, someother);
        const some: bool = false;
        try handle.addComponent(.somecomponent, some);
        break :a handle;
    };

    const entity_b: MyEcs.EntityHandle = a: {
        var handle = try ecs.entities.register();
        const someother: u32 = 7;
        try handle.addComponent(MyEcs.ComponentTag.someothercomponent, someother);
        const some: bool = true;
        try handle.addComponent(MyEcs.ComponentTag.somecomponent, some);
        break :a handle;
    };

    var entity_c: MyEcs.EntityHandle = a: {
        const handle = try ecs.entities.register();
        break :a handle;
    };

    // Entity Component Validation
    // ---
    {
        const got = ecs.components.access(u32, MyEcs.ComponentTag.someothercomponent, entity_a.index().?) orelse @panic("Nothing at that index");
        try std.testing.expectEqual(got.*, 5);
    }
    {
        const got = ecs.components.access(bool, MyEcs.ComponentTag.somecomponent, entity_a.index().?) orelse @panic("Nothing at that index");
        try std.testing.expectEqual(got.*, false);
    }
    {
        const got = ecs.components.access(u32, MyEcs.ComponentTag.someothercomponent, entity_b.index().?) orelse @panic("Nothing at that index");
        try std.testing.expectEqual(got.*, 7);
    }
    {
        const got = ecs.components.access(bool, MyEcs.ComponentTag.somecomponent, entity_b.index().?) orelse @panic("Nothing at that index");
        try std.testing.expectEqual(got.*, true);
    }
    {
        const got = ecs.components.access(bool, MyEcs.ComponentTag.somecomponent, entity_c.index().?);
        try std.testing.expect(got == null);
    }

    var all: [5]Entity = undefined;
    @memset(&all, 0);

    const query = MyEcs.Query{ .query = .{ .is = .{ .rule = .exact, .sig = s: {
        var s = MyEcs.Signature.initEmpty();
        s.set(@intFromEnum(MyEcs.ComponentTag.somecomponent));
        s.set(@intFromEnum(MyEcs.ComponentTag.someothercomponent));
        break :s s;
    } } } };

    const matching = try ecs.queryEntities(query) orelse @panic("NOTHING MATCHING");

    std.log.debug("got matching: {any}\n", .{matching});

    const containsEntityWithId = struct {
        fn contains(qu: []MyEcs.EntityHandle, id: Entity) bool {
            for (qu) |handle| {
                if (handle.identifier == id) {
                    return true;
                }
            }
            return false;
        }
    }.contains;
    try std.testing.expect(containsEntityWithId(matching.query, entity_a.identifier));
    try std.testing.expect(containsEntityWithId(matching.query, entity_b.identifier));

    // Component Removal
    // ---

    {
        const removed = ecs.components.removeWithReturn(bool, MyEcs.ComponentTag.somecomponent, entity_a.index().?) orelse @panic("nothing at that index");
        try std.testing.expectEqual(removed.*, false);
        try std.testing.expectEqual(null, ecs.components.access(bool, MyEcs.ComponentTag.somecomponent, entity_a.index().?));
    }

    // Entity Index Storage
    // ---
    {
        try std.testing.expectEqual(0, ecs.entities.manager.index_map.get(entity_a.identifier));
        try std.testing.expectEqual(1, ecs.entities.manager.index_map.get(entity_b.identifier));
        try std.testing.expectEqual(2, ecs.entities.manager.index_map.get(entity_c.identifier));

        // adding component to `entity_c` to make sure the component data is moved as expected
        const val: u8 = 64;
        try entity_c.addComponent(.othercomponent, val);

        try entity_a.destroy();
        try std.testing.expectEqual(0, ecs.entities.manager.index_map.get(entity_c.identifier));
        try std.testing.expectEqual(0, entity_c.index().?);

        const got = ecs.components.access(u8, .othercomponent, entity_c.index().?);
        try std.testing.expectEqual(val, got.?.*);
    }

    // Systems
    // ---
    const SomeSysState =
        struct {
            call_count: u32,

            pub fn startup(self: *@This(), myecs: *MyEcs) anyerror!void {
                self.call_count += 1;
                _ = myecs;
            }
            pub fn run(self: *@This(), myecs: *MyEcs, state: *State) anyerror!void {
                const q =
                    MyEcs.Query{ .query = .{
                        .is = MyEcs.QueryStatement.new(.at_least, &[_]MyEcs.ComponentTag{.someothercomponent}),
                    } };

                const result = try myecs.queryEntities(q);
                _ = state;
                warn("IN SOME SYSTEM\n", .{});
                self.call_count += 1;
                for (result.?.query) |e| {
                    warn("MUTATING ENTITY: {}", .{e});
                    const idx = e.index() orelse @panic("ENTITY SHOULD HAVE AN INDEX?");
                    const v = myecs.components.access(u32, .someothercomponent, idx) orelse @panic("SHOULD HAVE THIS COMPONENT?");
                    warn("VAL: {}", .{v.*});
                    const new: u32 = 1111;
                    myecs.components.insert(myecs.allocator, .someothercomponent, idx, new) catch @panic("FAILED TO INSERT COMPONENT");
                }
            }
        };
    // const some_system_st = try ecs.allocator.create(SomeSysState);
    const some_system_st = SomeSysState{ .call_count = 0 };
    const some_system = try MyEcs.System.init(ecs.allocator, SomeSysState, some_system_st);
    // const some_system = try ecs.initSystem(SomeSysState, some_system_st);
    const sys_id, const sys_idx = try ecs.registerSystem(some_system, .pre_render);

    // try ecs.startSytems();
    try ecs.startSytem(sys_id);

    var state = State{};
    try ecs.runSystems(&state);

    {
        const got = ecs.components.access(u32, MyEcs.ComponentTag.someothercomponent, entity_b.index().?) orelse @panic("Nothing at that index");
        try std.testing.expectEqual(
            1111,
            got.*,
        );
        try std.testing.expect(blk: {
            const st: *SomeSysState = @ptrCast(@alignCast(ecs.systems.all.data[sys_idx].?.inner));
            break :blk st.*.call_count == 2;
        });
    }

    std.debug.print(
        \\ ENTITY MANAGEMENT & SYSTEMS WORKS AS EXPECTED
        \\
    , .{});
}
