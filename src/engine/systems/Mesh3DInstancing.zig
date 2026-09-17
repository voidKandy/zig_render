const std = @import("std");
const core = @import("../../root.zig");
const log = std.log.scoped(.Mesh3DInstancingSystem);
const imgui = core.clibs.imgui;
const vk = core.clibs.vk;
const Meshes3D = core.resources.Meshes3D;
const Mesh3DInstancing = @This();

const Transform = extern struct {
    position: core.lib.math.Vec3 = .ZERO,
    scale: core.lib.math.Vec3 = .ONE,
    rotation: core.lib.math.Mat4 = .IDENTITY,
};

const Instance = extern struct {
    mesh_idx: u32,
    material_idx: u32,
    model_transform: core.lib.math.Mat4,

    // transform: Transform = .{},
};

/// indices into instance buffer per mesh index
instance_map: std.AutoHashMapUnmanaged(u32, core.lib.mesh.RangeDesc),
instances: []Instance,

pub const INSTANCES_BUFFER_NAME = "instances";
pub const INSTANCE_SET_NAME = "instance_set";

pub const InstanceCreateData = struct {
    material_name: []const u8,
    mesh_name: []const u8,
    transform: Transform = .{},
};

pub fn init(
    a: std.mem.Allocator,
    resources: *core.resources.Manager,
    /// MUST BE GROUPED BY MESH INDEX
    /// will break otherwise
    /// TODO fix this
    cis: []const InstanceCreateData,
    // world: *core.engine.world.GameWorld,
    // swapchain_extent: vk.Extent2D,
) std.mem.Allocator.Error!@This() {
    var list = try std.ArrayList(Instance).initCapacity(a, cis.len);

    try resources.mapped_buffers.creates.put(
        a,
        INSTANCES_BUFFER_NAME,
        .{
            .alloc_size = @sizeOf(Instance * cis.len),
            .buffer_usage = vk.BUFFER_USAGE_UNIFORM_BUFFER_BIT,
            .mem_usage = core.clibs.vma.MEMORY_USAGE_CPU_TO_GPU,
            .flags = 0,
        },
    );

    var inst_map = std.AutoHashMapUnmanaged(u32, core.lib.mesh.RangeDesc).empty;

    for (cis, 0..) |ci, i| {
        const material_idx = resources.materials.material_indices.get(ci.material_name) orelse std.debug.panic(
            \\ Could not find material for '{s}'
        , .{ci.material_name});
        const mesh_idx = resources.meshes3D.mesh_indices.get(ci.mesh_name) orelse std.debug.panic(
            \\ Could not find mesh for '{s}'
        , .{ci.mesh_name});

        const result = try inst_map.getOrPut(a, @as(u32, @intCast(mesh_idx)));
        if (result.found_existing) {
            result.value_ptr.*.range += 1;
        } else {
            result.* = .{
                .offset = i,
                .range = 1,
            };
        }

        list.appendAssumeCapacity(.{
            .material_idx = material_idx,
            .mesh_idx = mesh_idx,
            .transform = ci.transform,
        });
    }

    return .{
        .instance_map = inst_map,
        .instances = try list.toOwnedSlice(a),
    };
}

pub fn deinit(self: *@This(), allocs: core.engine.Allocators) void {
    self.mesh3d_data.deinit(allocs.std);
    self.edited_mesh3ds.deinit(allocs.std);
    self.edited_mesh2ds.deinit(allocs.std);
}

pub fn registerSets(
    a: std.mem.Allocator,
    device: vk.Device,
    resources: *core.resources.Manager,
    alloc_cbs: ?*vk.AllocationCallbacks,
) std.mem.Allocator.Error!void {
    try resources.mapped_buffers.createAndRegisterBufferSetLayout(
        a,
        INSTANCE_SET_NAME,
        &[_]core.resources.MappedBuffers.CreateBufferInfo{
            .{
                .name = INSTANCES_BUFFER_NAME,
                .descriptor_type = vk.DESCRIPTOR_TYPE_UNIFORM_BUFFER,
                .binding = 0,
                .stage_flags = vk.SHADER_STAGE_VERTEX_BIT,
            },
        },
        device,
        alloc_cbs,
    );
}

fn createEntities(
    a: std.mem.Allocator,
    _: std.Io,
    _: *core.engine.world.GameWorld,
    resources: core.resources.Manager,
) std.mem.Allocator.Error![]u32 {
    _ = try std.ArrayList(u32).initCapacity(a, 64);
    _ = resources.meshes3D.meshes.items[0];
}

pub fn trySyncResources(self: *@This(), alloc_resources: core.resources.Manager.AllocatedData) void {
    const aligned: [*]Instance = @ptrCast(
        @alignCast(alloc_resources.mapped_buffers.buffers.get(INSTANCES_BUFFER_NAME).?.mapped),
    );
    @memcpy(aligned, self.instances);
}

pub fn drawImgui(
    self: *@This(),
    a: std.mem.Allocator,
    pipeline: *core.engine.graphics_pipelines.Mesh3DPipeline,
    world: *core.engine.world.GameWorld,
    resources: core.resources.Manager,
    alloc_resources: core.resources.Manager.AllocatedData,
) void {
    var open = true;
    const shown = imgui.Begin("Mesh 3DInstancing System", &open, core.clibs.imgui.WINDOW_ALWAYS_AUTO_RESIZE);
    defer imgui.End();

    if (!shown) return;

    const current_pipeline_name = @tagName(pipeline.current_pipeline);

    if (imgui.BeginCombo("Selected Pipeline", current_pipeline_name.ptr, 0)) {
        defer imgui.EndCombo();

        for (std.meta.tags(core.engine.graphics_pipelines.Mesh3DPipeline.PipelineOptions)) |tag| {
            const name = @tagName(tag);
            if (imgui.Selectable(name))
                pipeline.current_pipeline = tag;
        }
    }

    var idx: usize = 0;
    const m3D_query = core.engine.world.GameWorld.Query{ .is = .{
        .rule = .at_least,
        .sig = core.engine.world.GameWorld.Signature.initOne(.mesh3D),
    } };
    var m3D_entities_iter = world.queryEntities(m3D_query);
    imgui.Text("3D Meshes");

    while (m3D_entities_iter.next()) |handle| : (idx += 1) {
        var mutable_handle = handle;

        const mesh_component =
            mutable_handle.accessComponent(.mesh3D) catch unreachable;

        const mesh: core.engine.world.MaterialMesh3D = mesh_component.mesh3D;

        const ranges = mesh.handle.ranges;
        const mesh_metadatas =
            resources.meshes3D.meta_data.items[ranges.metadata.offset .. ranges.metadata.offset + ranges.metadata.range];

        var transform = mesh_metadatas[0].model_transform;

        const label = std.fmt.allocPrintSentinel(
            std.heap.c_allocator,
            "Mesh3D {d}",
            .{idx},
            0,
        ) catch @panic("OOM");
        defer std.heap.c_allocator.free(label);

        if (imgui.TreeNode(label)) {
            defer imgui.TreePop();

            var mat_idx: c_int = @intCast(mesh_metadatas[0].material_index);

            const mat_name = alloc_resources.materials.material_names_reverse_lookup.get(@as(usize, @intCast(mat_idx))).?;
            imgui.Text("Material Name: %s", mat_name.ptr);

            if (imgui.InputInt("Material Index", &mat_idx)) {
                mesh_metadatas[0].material_index = @as(u32, @intCast(mat_idx));
                self.markMesh3DEdited(a, handle.identifier);
            }

            var translation: [3]f32 = .{
                transform.t.x,
                transform.t.y,
                transform.t.z,
            };

            if (imgui.DragFloat3("Position", &translation)) {
                transform.t.x = translation[0];
                transform.t.y = translation[1];
                transform.t.z = translation[2];

                mesh_metadatas[0].model_transform = transform;

                self.markMesh3DEdited(
                    a,
                    handle.identifier,
                );
            }

            var scale_factor = blk: {
                const result = self.mesh3d_data.getOrPut(a, handle.identifier) catch @panic("OOM");
                break :blk if (result.found_existing)
                    result.value_ptr.scale_factor
                else
                    1.0;
            };
            if (imgui.SliderFloat("Scale", &scale_factor, 0.0, 10.0)) {
                if (scale_factor != 1.0) {
                    self.mesh3d_data.put(a, handle.identifier, .{ .scale_factor = scale_factor }) catch @panic("OOM");
                    const s = core.lib.math.Mat4.scale(core.lib.math.Vec3.make(scale_factor, scale_factor, scale_factor));
                    const t = core.lib.math.Mat4.translation(core.lib.math.Vec3.make(translation[0], translation[1], translation[2]));
                    mesh_metadatas[0].model_transform = core.lib.math.Mat4.mul(t, s);

                    self.markMesh3DEdited(a, handle.identifier);
                }
            }
        }
    }

    imgui.Separator();

    const m2D_query = core.engine.world.GameWorld.Query{ .is = .{
        .rule = .at_least,
        .sig = core.engine.world.GameWorld.Signature.initOne(.mesh2D),
    } };
    var m2D_entities_iter = world.queryEntities(m2D_query);
    imgui.Text("2D Meshes");

    idx = 0;

    while (m2D_entities_iter.next()) |handle| : (idx += 1) {
        var mutable_handle = handle;

        const mesh_component =
            mutable_handle.accessComponent(.mesh2D) catch unreachable;

        const mesh: core.engine.world.Mesh2DComponent = mesh_component.mesh2D;

        var md =
            &resources.meshes2D.meta_data.items[mesh.ranges.metadata_idx];

        var screen_coords = md.screen_coordinates;

        const label = std.fmt.allocPrintSentinel(
            std.heap.c_allocator,
            "Mesh2D {d}",
            .{idx},
            0,
        ) catch @panic("OOM");
        defer std.heap.c_allocator.free(label);

        if (imgui.TreeNode(label)) {
            defer imgui.TreePop();

            var mat_idx: c_int = @intCast(md.material_index);

            const mat_name = alloc_resources.materials.material_names_reverse_lookup.get(@as(usize, @intCast(mat_idx))).?;
            imgui.Text("Material Name: %s", mat_name.ptr);

            if (imgui.InputInt("Material Index", &mat_idx)) {
                md.material_index = @as(u32, @intCast(mat_idx));
                self.markMesh2DEdited(a, handle.identifier);
            }

            var translation: [2]f32 = .{
                screen_coords.x,
                screen_coords.y,
            };

            if (imgui.SliderFloat2("Position", &translation, 0.0, 1.0)) {
                screen_coords.x = translation[0];
                screen_coords.y = translation[1];

                md.screen_coordinates = screen_coords;

                self.markMesh2DEdited(
                    a,
                    handle.identifier,
                );
            }
        }
    }

    imgui.Separator();
}
