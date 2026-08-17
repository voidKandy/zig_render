const rl = @import("raylib");
const std = @import("std");
const zbt = @import("zbullet");
const core = @import("../root.zig");
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

        const SEED = 42;
        pub fn init(allocator: Allocator) (std.posix.OpenError || Allocator.Error)!Manager {
            var prng = std.Random.DefaultPrng.init(SEED);
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

        pub fn getData(self: Manager, entity_id: u32) ?T {
            const idx = self.index_map.get(entity_id) orelse return null;
            return self.data[idx];
        }

        pub fn getDataPtr(self: *Manager, entity_id: u32) ?*T {
            const idx = self.index_map.get(entity_id) orelse return null;
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

pub const EcsOptions = struct {
    max_entities: usize,
    /// Components are declared by a simple struct
    /// fieldnames and their types define what components
    /// map to which type and what name
    components: type,
};

/// Does not care about how `System` part of the ECS is implemented
/// caller is expected to have their own `System` system
/// should leverage querying and storage of components provided by this type
pub fn EntityStore(
    comptime Options: EcsOptions,
) type {
    if (Options.max_entities == 0) {
        @compileError("Set Options.max_entities to at least 1!");
    }
    return struct {
        const ThisStore = @This();
        pub const Opts = Options;
        const N_COMPONENTS: usize =
            @intCast(@typeInfo(Options.components).@"struct".fields.len);
        entities: EntityManager,
        components: ComponentsManager,

        pub fn init(a: Allocator) Allocator.Error!ThisStore {
            return ThisStore{
                .entities = EntityManager.init(a),
                .components = ComponentsManager.init(),
            };
        }
        pub fn deinit(self: *ThisStore, a: Allocator) void {
            self.entities.manager.deinit(a);
        }

        /// Archetypes can easily be expressed through signatures:
        /// ```zig
        /// var archetype = Signature.initZeros();
        /// archetype.set(@intFromEnum(ComponentTag.mycomponent));
        /// archetype.set(@intFromEnum(ComponentTag.othercomponent));
        /// ```
        pub const Signature = std.bit_set.IntegerBitSet(N_COMPONENTS);

        pub fn entityHandle(self: *ThisStore, entity_id: u32) error{NoData}!EntityHandle {
            var sig =
                self.entities.manager.getData(entity_id) orelse return error.NoData;
            return EntityHandle{ .ecs = self, .identifier = entity_id, .signature = &sig };
        }
        /// Returns the signature associated with the given component
        pub fn componentSignature(tag: Meta.ComponentTag) Signature {
            var sig = Signature.initEmpty();
            sig.set(@intFromEnum(tag));
            return sig;
        }
        /// Returns the signature associated with the given component
        pub fn componentsSignature(tags: []Meta.ComponentTag) Signature {
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
        pub inline fn componentType(variant: Meta.ComponentTag) type {
            const idx = @intFromEnum(variant);
            return @typeInfo(Options.components).@"struct".fields[idx].type;
        }

        pub fn queryEntities(self: *ThisStore, query: Query) QueryIterator {
            return .{
                .ecs = self,
                .query = query,
            };
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
            pub fn new(rule: QueryRule, components: []const Meta.ComponentTag) @This() {
                return .{ .rule = rule, .sig = componentsSignature(@constCast(components)) };
            }
        };

        /// Query can either directly look for an entity by id (id)
        /// or they can be queried by component signature (query)
        pub const QueryType = enum { id, query };
        pub const Query = struct {
            is: ?QueryStatement = null,
            is_not: ?QueryStatement = null,
        };

        pub const QueryIterator = struct {
            ecs: *ThisStore,
            query: Query,
            index: usize = 0,

            pub fn next(self: *@This()) ?EntityHandle {
                while (self.index < self.ecs.entities.manager.count) {
                    const idx = self.index;
                    self.index += 1;

                    const sig = self.ecs.entities.manager.data[idx] orelse unreachable;

                    if (self.query.is) |is| {
                        if (!is.rule.cmpFn()(sig, is.sig))
                            continue;
                    }

                    if (self.query.is_not) |is_not| {
                        if (is_not.rule.cmpFn()(sig, is_not.sig))
                            continue;
                    }

                    const id = self.ecs.entities.manager.getId(idx) orelse unreachable;

                    return self.ecs.entityHandle(id) catch unreachable;
                }

                return null;
            }
        };

        pub const Meta = struct {
            names: [N_COMPONENTS][]const u8 = undefined,
            types: [N_COMPONENTS]type = undefined,
            /// fields for the ComponentArrays struct that stores arrays for each component type
            struct_field_types: [N_COMPONENTS]type = undefined,
            struct_field_attrs: [N_COMPONENTS]Type.StructField.Attributes = undefined,

            enum_vals: [N_COMPONENTS]u32 = undefined,

            un_field_attrs: [N_COMPONENTS]Type.UnionField.Attributes = undefined,
            un_ptr_types: [N_COMPONENTS]type = undefined,

            const STATIC: @This() = blk: {
                var meta = @This(){};
                for (
                    @typeInfo(Options.components).@"struct".fields,
                    &meta.names,
                    &meta.types,
                    &meta.enum_vals,
                    &meta.struct_field_types,
                    &meta.struct_field_attrs,
                    &meta.un_field_attrs,
                    &meta.un_ptr_types,
                    0..,
                ) |
                    field,
                    *fnm,
                    *ftyp,
                    *envl,
                    *strtyp,
                    *stfld_att,
                    *unfld_att,
                    *unptr_typ,
                    i,
                | {
                    fnm.* = field.name;
                    ftyp.* = field.type;
                    envl.* = i;
                    strtyp.* = [Options.max_entities]?field.type;
                    stfld_att.* = .{};
                    unfld_att.* = Type.UnionField.Attributes{
                        .@"align" = @alignOf(field.type),
                    };
                    unptr_typ.* = *field.type;
                }
                break :blk meta;
            };

            pub const ComponentArrays =
                @Struct(
                    .auto,
                    null,
                    &STATIC.names,
                    &STATIC.struct_field_types,
                    &STATIC.struct_field_attrs,
                );

            pub const ComponentTag = @Enum(u32, .exhaustive, &STATIC.names, &STATIC.enum_vals);
            pub const ComponentUnion = @Union(.auto, ComponentTag, &STATIC.names, &STATIC.types, &STATIC.un_field_attrs);
            pub const ComponentPtrUnion = @Union(.auto, null, &STATIC.names, &STATIC.un_ptr_types, &STATIC.un_field_attrs);

            const ALL_COMPONENT_TAGS: [N_COMPONENTS]ComponentTag = blk: {
                var all: [N_COMPONENTS]ComponentTag = undefined;
                for (0..N_COMPONENTS) |i| {
                    all[i] = @enumFromInt(i);
                }
                break :blk all;
            };
        };

        const ComponentsManager = struct {
            arrays: Meta.ComponentArrays,

            pub fn init() @This() {
                var self: @This() = undefined;

                inline for (Meta.STATIC.names) |name| {
                    @memset(&@field(self.arrays, name), null);
                }

                return self;
            }

            fn get(self: @This(), comptime which: Meta.ComponentTag, idx: usize) ?Meta.ComponentUnion {
                return @unionInit(Meta.ComponentUnion, @tagName(which), @field(self.arrays, @tagName(which))[idx] orelse return null);
            }

            fn getPtr(self: @This(), comptime which: Meta.ComponentTag, idx: usize) ?Meta.ComponentPtrUnion {
                return @unionInit(Meta.ComponentPtrUnion, @tagName(which), &@field(self.arrays, @tagName(which))[idx] orelse return null);
            }

            // expects to be passed `T` for `component`
            // **NEVER** use multiple allocators for a single instance
            pub fn insert(self: *@This(), comptime which: Meta.ComponentTag, idx: usize, component: anytype) void {
                if (@FieldType(Meta.ComponentUnion, @tagName(which)) != @TypeOf(component)) @compileError("Passed invalid type to insert!");

                @field(self.arrays, @tagName(which))[idx] = component;
            }

            /// moves component at `idx` to `to_idx`
            /// Nullifies data that was previously at `to_idx`
            fn swap(self: *@This(), comptime which: Meta.ComponentTag, idx: usize, to_idx: usize) void {
                var arr = @field(self.arrays, @tagName(which));
                const tmp = arr[idx];
                arr[to_idx] = tmp;
                arr[idx] = null;
                @field(self.arrays, @tagName(which)) = arr;
            }

            /// This function does not ensure that the entity's associated signature is unset for this component!!
            fn removeNoReturn(self: *@This(), comptime which: Meta.ComponentTag, idx: usize) void {
                @field(self.arrays, @tagName(which))[idx] = null;
                return;
            }

            /// This function does not ensure that the entity's associated signature is unset for this component!!
            fn removeWithReturn(self: *@This(), comptime which: Meta.ComponentTag, idx: usize) ?Meta.ComponentUnion {
                const val = self.get(which, idx) orelse return null;
                self.removeNoReturn(which, idx);
                return val;
            }
        };

        /// Returns the function by which `Entity`s are compared according to a `Query`'s rule
        /// Helper struct for easily managing any components associated with an entity
        pub const EntityHandle = struct {
            ecs: *ThisStore,
            identifier: u32,
            signature: *Signature,
            name: ?[]const u8 = null,

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
                    // unfortunately we need to do this because of the comptime requirements of removeNoReturn
                    inline for (Meta.ALL_COMPONENT_TAGS) |tag|
                        if (sig.isSet(@intFromEnum(tag)))
                            self.ecs.components.removeNoReturn(tag, idx);
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
                        inline for (Meta.ALL_COMPONENT_TAGS) |tag| {
                            if (sig.isSet(@intFromEnum(tag))) {
                                self.ecs.components.swap(tag, prev_idx_of_moved_ent, idx);
                            }
                        }
                    }
                }
            }

            pub fn accessComponent(
                self: *@This(),
                which: Meta.ComponentTag,
            ) error{AccessFailed}!Meta.ComponentUnion {
                inline for (Meta.ALL_COMPONENT_TAGS) |t| {
                    if (t == which)
                        if (self.ecs.components.get(t, self.index().?)) |c| return c;
                }
                return error.AccessFailed;
            }

            pub fn removeComponent(self: *@This(), which: Meta.ComponentTag, component: anytype) void {
                const idx = self.index() orelse @panic("NO INDEX?");
                var sig = self.ecs.entities.manager.data[idx];
                sig.unset(@intFromEnum(which));
                self.ecs.components.removeNoReturn(@TypeOf(component), which, idx);
            }

            pub fn addComponent(self: *@This(), comptime which: Meta.ComponentTag, component: anytype) void {
                const idx = self.index() orelse @panic("NO INDEX?");
                var sig = self.ecs.entities.manager.data[idx] orelse @panic("NO DATA?");
                std.log.debug("sig: {b}\n", .{sig.mask});
                sig.set(@intFromEnum(which));
                std.log.debug("changed sig: {b}\n", .{sig.mask});
                self.ecs.entities.manager.data[idx] = sig;
                self.ecs.components.insert(which, idx, component);
            }
        };

        const EntityManager = struct {
            manager: IdentifierManager(Signature, Options.max_entities),

            fn init(allocator: Allocator) @This() {
                return .{ .manager = IdentifierManager(Signature, Options.max_entities).init(allocator) catch @panic("Could not create IdentifierManager for Entities") };
            }

            /// Creates an empty with an empty `Signature`
            pub fn register(self: *@This(), name: ?[]const u8) Allocator.Error!EntityHandle {
                const id, const i = try self.manager.register(Signature.initEmpty());
                // _ = i;
                var parent_ptr =
                    @as(*ThisStore, @fieldParentPtr("entities", self));
                _ = &parent_ptr;

                return EntityHandle{
                    .ecs = parent_ptr,
                    .identifier = id,
                    .signature = &self.manager.data[i].?,
                    .name = name,
                };
            }
        };
    };
}

test "ECS Entity Management" {
    std.testing.refAllDecls(@This());
    const a = std.testing.allocator;

    std.debug.print(
        \\
        \\ ---INIT ECS TEST---
        \\
    , .{});

    const MyEcs = EntityStore(.{
        .max_entities = 5,
        .components = struct {
            somecomponent: bool,
            othercomponent: u8,
            someothercomponent: u32,
        },
    });
    var ecs = try MyEcs.init(a);
    defer ecs.deinit(a);

    // Entity Initialization
    // ---
    const entity_a: MyEcs.EntityHandle = a: {
        var handle = try ecs.entities.register(null);
        const someother: u32 = 5;
        handle.addComponent(.someothercomponent, someother);
        const some: bool = false;
        handle.addComponent(.somecomponent, some);
        break :a handle;
    };

    const entity_b: MyEcs.EntityHandle = a: {
        var handle = try ecs.entities.register(null);
        const someother: u32 = 7;
        handle.addComponent(.someothercomponent, someother);
        const some: bool = true;
        handle.addComponent(.somecomponent, some);
        break :a handle;
    };

    var entity_c: MyEcs.EntityHandle = a: {
        const handle = try ecs.entities.register(null);
        break :a handle;
    };

    // Entity Component Validation
    // ---
    {
        const got = ecs.components.get(.someothercomponent, entity_a.index().?) orelse @panic("Nothing at that index");
        try std.testing.expectEqual(got, MyEcs.Meta.ComponentUnion{ .someothercomponent = 5 });
    }
    {
        const got = ecs.components.get(.somecomponent, entity_a.index().?) orelse @panic("Nothing at that index");
        try std.testing.expectEqual(got, MyEcs.Meta.ComponentUnion{ .somecomponent = false });
    }
    {
        const got = ecs.components.get(.someothercomponent, entity_b.index().?) orelse @panic("Nothing at that index");
        try std.testing.expectEqual(got, MyEcs.Meta.ComponentUnion{ .someothercomponent = 7 });
    }
    {
        const got = ecs.components.get(.somecomponent, entity_b.index().?) orelse @panic("Nothing at that index");
        try std.testing.expectEqual(got, MyEcs.Meta.ComponentUnion{ .somecomponent = true });
    }
    {
        const got = ecs.components.get(.somecomponent, entity_c.index().?);
        try std.testing.expect(got == null);
    }

    var all: [5]u32 = undefined;
    @memset(&all, 0);

    const query = MyEcs.Query{ .query = .{ .is = .{ .rule = .exact, .sig = s: {
        var s = MyEcs.Signature.initEmpty();
        s.set(@intFromEnum(MyEcs.Meta.ComponentTag.somecomponent));
        s.set(@intFromEnum(MyEcs.Meta.ComponentTag.someothercomponent));
        break :s s;
    } } } };

    const iter = try ecs.queryEntities(a, query) orelse @panic("NOTHING MATCHING");

    const containsEntityWithId = struct {
        fn contains(qu: MyEcs.QueryIterator, id: u32) bool {
            var clone = qu;
            while (clone.next()) |handle| {
                if (handle.identifier == id) {
                    return true;
                }
            }
            return false;
        }
    }.contains;
    try std.testing.expect(containsEntityWithId(iter, entity_a.identifier));
    try std.testing.expect(containsEntityWithId(iter, entity_b.identifier));

    // Component Removal
    // ---

    {
        const removed = ecs.components.removeWithReturn(MyEcs.Meta.ComponentTag.somecomponent, entity_a.index().?) orelse @panic("nothing at that index");
        try std.testing.expectEqual(removed.somecomponent, false);
        try std.testing.expectEqual(null, ecs.components.get(MyEcs.Meta.ComponentTag.somecomponent, entity_a.index().?));
    }

    // Entity Index Storage
    // ---
    {
        try std.testing.expectEqual(0, ecs.entities.manager.index_map.get(entity_a.identifier));
        try std.testing.expectEqual(1, ecs.entities.manager.index_map.get(entity_b.identifier));
        try std.testing.expectEqual(2, ecs.entities.manager.index_map.get(entity_c.identifier));

        // adding component to `entity_c` to make sure the component data is moved as expected
        const val: u8 = 64;
        entity_c.addComponent(.othercomponent, val);

        try entity_a.destroy();
        try std.testing.expectEqual(0, ecs.entities.manager.index_map.get(entity_c.identifier));
        try std.testing.expectEqual(0, entity_c.index().?);

        const got = ecs.components.get(.othercomponent, entity_c.index().?);
        try std.testing.expectEqual(val, got.?.othercomponent);
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
            pub fn run(self: *@This(), myecs: *MyEcs) anyerror!void {
                const q =
                    MyEcs.Query{ .query = .{
                        .is = MyEcs.QueryStatement.new(.at_least, &[_]MyEcs.Meta.ComponentTag{.someothercomponent}),
                    } };

                var query_iter = myecs.queryEntities(a, q);
                warn("IN SOME SYSTEM\n", .{});
                self.call_count += 1;
                while (query_iter.next()) |e| {
                    warn("MUTATING ENTITY: {}", .{e});
                    const idx = e.index() orelse @panic("ENTITY SHOULD HAVE AN INDEX?");
                    const v = myecs.components.get(.someothercomponent, idx) orelse @panic("SHOULD HAVE THIS COMPONENT?");
                    warn("VAL: {}", .{v.someothercomponent});
                    const new: u32 = 1111;
                    myecs.components.insert(.someothercomponent, idx, new);
                }
            }
        };
    var some_system_st = SomeSysState{ .call_count = 0 };
    try some_system_st.startup(&ecs);

    try some_system_st.run(&ecs);
    {
        const got = ecs.components.get(.someothercomponent, entity_b.index().?) orelse @panic("Nothing at that index");
        try std.testing.expectEqual(
            1111,
            got.someothercomponent,
        );
        try std.testing.expect(some_system_st.call_count == 2);
    }

    std.debug.print(
        \\ ENTITY MANAGEMENT & SYSTEMS WORKS AS EXPECTED
        \\
    , .{});
}
