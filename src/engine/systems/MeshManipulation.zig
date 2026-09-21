const std = @import("std");
const core = @import("../../root.zig");
const log = std.log.scoped(.MeshManipulationSystem);
const imgui = core.clibs.imgui;
const Meshes3D = core.resources.Meshes3D;
const Meshes2D = core.resources.Meshes2D;
const MeshManipulation = @This();

/// system side data associated with meshes
mesh3d_data: std.AutoHashMapUnmanaged(u32, struct {
    /// allows for abitrary scaling of meshes
    scale_factor: f32,
}) = .empty,
/// edited meshes by entity id
edited_mesh3ds: std.ArrayListUnmanaged(u32) = .empty,

edited_mesh2ds: std.ArrayListUnmanaged(u32) = .empty,

pub fn deinit(self: *@This(), allocs: core.engine.Allocators) void {
    self.mesh3d_data.deinit(allocs.std);
    self.edited_mesh3ds.deinit(allocs.std);
    self.edited_mesh2ds.deinit(allocs.std);
}

pub fn trySyncResources(
    self: *@This(),
    resources: core.resources.Manager,
    alloc_resources: core.resources.Manager.AllocatedData,
    world: *core.engine.world.GameWorld,
) void {
    if (self.edited_mesh3ds.items.len > 0) {
        const aligned_metadatas: [*]Meshes3D.MetaData = @ptrCast(@alignCast(alloc_resources.meshes3D.metadata.mapped));
        for (self.edited_mesh3ds.items) |id| {
            var mesh_entity = world.entityHandle(id) catch std.debug.panic(
                \\ No entity matching id: {}
            , .{id});
            const mesh_component = mesh_entity.accessComponent(.mesh3D) catch @panic("mesh component access failed");
            const mesh_handle = mesh_component.mesh3D.handle;
            const mds = resources.meshes3D.meta_data.items[mesh_handle.ranges.metadata.offset .. mesh_handle.ranges.metadata.offset + mesh_handle.ranges.metadata.range];
            for (0..mds.len) |k| {
                const md = mds[k];
                const gpu_md: Meshes3D.MetaData = .{
                    .material_index = md.material_index,
                    .index_offset = md.index_offset,
                    .index_count = md.index_count,
                    .vertex_offset = md.vertex_offset,
                    .model_transform = md.model_transform,
                };
                aligned_metadatas[k + mesh_handle.ranges.metadata.offset] = gpu_md;
            }
        }

        self.edited_mesh3ds.clearRetainingCapacity();
    }

    if (self.edited_mesh2ds.items.len > 0) {
        const aligned_metadatas: [*]Meshes2D.MetaData = @ptrCast(@alignCast(alloc_resources.meshes2D.metadata.mapped));
        for (self.edited_mesh2ds.items) |id| {
            var mesh_entity = world.entityHandle(id) catch std.debug.panic(
                \\ No entity matching id: {}
            , .{id});
            const mesh_component = mesh_entity.accessComponent(.mesh2D) catch @panic("mesh component access failed");
            const mesh_ranges = mesh_component.mesh2D.ranges;
            const md = resources.meshes2D.meta_data.items[mesh_ranges.metadata_idx];
            const gpu_md: Meshes2D.MetaData = .{
                .material_index = md.material_index,
                .screen_coordinates = md.screen_coordinates,
            };
            aligned_metadatas[mesh_ranges.metadata_idx] = gpu_md;
        }

        self.edited_mesh2ds.clearRetainingCapacity();
    }
}

fn markMesh3DEdited(
    self: *@This(),
    allocator: std.mem.Allocator,
    entity_id: u32,
) void {
    if (std.mem.indexOfScalar(u32, self.edited_mesh3ds.items, entity_id) == null) {
        self.edited_mesh3ds.append(allocator, entity_id) catch @panic("OOM");
    }
}
fn markMesh2DEdited(
    self: *@This(),
    allocator: std.mem.Allocator,
    entity_id: u32,
) void {
    if (std.mem.indexOfScalar(u32, self.edited_mesh2ds.items, entity_id) == null) {
        self.edited_mesh2ds.append(allocator, entity_id) catch @panic("OOM");
    }
}

pub fn drawImgui(
    self: *@This(),
    a: std.mem.Allocator,
    pipeline: *core.engine.pipelines.Mesh3DPipeline,
    world: *core.engine.world.GameWorld,
    resources: core.resources.Manager,
    alloc_resources: core.resources.Manager.AllocatedData,
) void {
    var open = true;
    const shown = imgui.Begin("Mesh Manipulation System", &open, core.clibs.imgui.WINDOW_ALWAYS_AUTO_RESIZE);
    defer imgui.End();

    if (!shown) return;

    const current_pipeline_name = @tagName(pipeline.current_pipeline);

    if (imgui.BeginCombo("Selected Pipeline", current_pipeline_name.ptr, 0)) {
        defer imgui.EndCombo();

        for (std.meta.tags(core.engine.pipelines.Mesh3DPipeline.PipelineOptions)) |tag| {
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

        const mesh: core.engine.world.MaterialMesh2D = mesh_component.mesh2D;

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
