//! core Library for zig render
const std = @import("std");
pub const clibs = @import("clibs/root.zig");

pub const bindings = struct {
    pub const vma_usage = @import("bindings/vma_usage.zig");
    pub const sdl_usage = @import("bindings/sdl_usage.zig");
    pub const vulkan_init = @import("bindings/vulkan_init.zig");
    pub const vulkan_util = @import("bindings/vulkan_util.zig");
    test {
        std.testing.refAllDecls(@This());
    }
};

pub const engine = struct {
    pub const Camera = @import("engine/Camera.zig");
    pub const world = @import("engine/world.zig");
    pub const Engine = @import("engine/Engine.zig");
    pub const frames = @import("engine/frames.zig");
    pub const GlobalAllocatedData = @import("engine/GlobalAllocatedData.zig");
    pub const Input = @import("engine/Input.zig");
    pub const shaders = @import("engine/shaders.zig");

    pub const pipelines = struct {
        pub const MeshPipeline = @import("engine/pipelines/MeshPipeline.zig");
        pub const HudPipelines = @import("engine/pipelines/HudPipelines.zig");
        pub const BackgroundPipeline = @import("engine/pipelines/BackgroundPipeline.zig");
        test {
            std.testing.refAllDecls(@This());
        }
    };

    test {
        std.testing.refAllDecls(@This());
    }
};

pub const lib = struct {
    pub const ecs = @import("lib/ecs.zig");
    pub const math = @import("lib/math.zig");
    pub const Maze = @import("lib/Maze.zig");
    pub const mesh = @import("lib/mesh.zig");
    pub const terrain = @import("lib/terrain.zig");
    // pub const alpha_wrapping = @import("lib/alpha_wrapping.zig");
    pub const delaunay = @import("lib/delaunay.zig");
    test {
        std.testing.refAllDecls(@This());
    }
};

pub const loaders = struct {
    pub const obj = @import("loaders/obj.zig");
    pub const mtl = @import("loaders/mtl.zig");
    test {
        std.testing.refAllDecls(@This());
    }
};

pub const resources = struct {
    pub const ResourceManager = struct {
        pub const Mesh3DCreateInfo = struct {
            create_mesh: union(enum) {
                obj: loaders.obj.ObjFile,
                info: struct {
                    mesh: lib.mesh.Mesh3D,
                    material_idx: u32,
                },
            },
            transform: lib.math.Mat4 = .IDENTITY,
        };

        pub const Mesh2DCreateInfo = struct {
            mesh: lib.mesh.Mesh2D,
            material_index: u32,
            screen_coordinates: lib.math.Vec2,
        };

        pub const CreateInfo = struct {
            materials_files: ?[]const loaders.mtl.MtlFile,
            meshes2D: ?[]const Mesh2DCreateInfo,
            meshes3D: ?[]const Mesh3DCreateInfo,
        };

        materials: Materials,
        meshes2D: Meshes2D,
        meshes3D: Meshes3D,

        pub fn deinit(
            self: *@This(),
            a: std.mem.Allocator,
        ) void {
            self.materials.deinit(a);
            self.meshes3D.deinit(a);
            self.meshes2D.deinit(a);
        }

        pub fn create(a: std.mem.Allocator, ci: CreateInfo) !@This() {
            var materials: Materials = undefined;

            if (ci.materials_files) |mtlfls| {
                materials = try .initFromMaterialsFiles(a, mtlfls);
            }

            var meshes3D = try Meshes3D.init(a);

            if (ci.meshes3D) |m3ds| {
                for (m3ds) |cm3d| {
                    switch (cm3d.create_mesh) {
                        .obj => |obj| {
                            const this_mat_lib = materials.libraries.get(obj.material_library_name) orelse std.debug.panic(
                                \\ Failed to get material library "{s}"
                            , .{obj.material_library_name});

                            const mesh = lib.mesh.Mesh3D.fromObjFile(a, obj) catch @panic("failed to load mesh");
                            defer mesh.deinit(a);
                            meshes3D.appendMeshWithMaterialLookup(
                                a,
                                mesh,
                                cm3d.transform,
                                this_mat_lib.offset,
                                this_mat_lib.library,
                                obj.objects[0].material_ranges,
                            ) catch @panic("OOM");
                        },
                        .info => |info| {
                            meshes3D.appendMeshWithMaterialIndex(
                                a,
                                info.mesh,
                                cm3d.transform,
                                info.material_idx,
                            ) catch @panic("OOM");
                        },
                    }
                }
            }

            var meshes2D = try resources.Meshes2D.init(a);
            if (ci.meshes2D) |m2ds| {
                for (m2ds) |cm2d| {
                    try meshes2D.appendMesh(
                        a,
                        cm2d.mesh,
                        cm2d.screen_coordinates,
                        cm2d.material_index,
                    );
                }
            }

            return @This(){
                .materials = materials,
                .meshes3D = meshes3D,
                .meshes2D = meshes2D,
            };
        }

        pub const AllocatedData = struct {
            materials: std.StringHashMapUnmanaged(Materials.MaterialLibrary.AllocatedData),
            meshes3D: Meshes3D.AllocatedData,
            meshes2D: Meshes2D.AllocatedData,

            pub fn deinit(
                self: *@This(),
                allocs: engine.Engine.Allocators,
                device: clibs.vk.Device,
                alloc_cbs: ?*clibs.vk.AllocationCallbacks,
            ) void {
                var iter = self.materials.valueIterator();
                while (iter.next()) |m| {
                    m.deinit(allocs, device, alloc_cbs);
                }
                self.materials.deinit(allocs.std);
                self.meshes3D.deinit(allocs);
                self.meshes2D.deinit(allocs);
            }
        };

        pub fn upload(
            self: *@This(),
            allocs: engine.Engine.Allocators,
            upload_ctx: *bindings.vulkan_init.UploadContext,
            logical_device: bindings.vulkan_init.LogicalDevice,
            physical_device: bindings.vulkan_init.PhysicalDevice,
            alloc_cbs: ?*clibs.vk.AllocationCallbacks,
        ) AllocatedData {
            var materials = std.StringHashMapUnmanaged(Materials.MaterialLibrary.AllocatedData).empty;
            var mat_libs_iter = self.materials.libraries.iterator();
            while (mat_libs_iter.next()) |mat| {
                const uploaded = mat.value_ptr.library.upload(
                    allocs,
                    upload_ctx,
                    logical_device,
                    physical_device,
                    alloc_cbs,
                );
                materials.put(allocs.std, mat.key_ptr.*, uploaded) catch @panic("OOM");
            }
            const meshes3D = self.meshes3D.upload(
                allocs,
                upload_ctx,
                logical_device,
            );
            const meshes2D = self.meshes2D.upload(
                allocs,
                upload_ctx,
                logical_device,
            );

            return .{
                .meshes3D = meshes3D,
                .meshes2D = meshes2D,
                .materials = materials,
            };
        }
    };

    pub const Materials = @import("resources/Materials.zig");
    pub const Meshes2D = @import("resources/Meshes2D.zig");
    pub const Meshes3D = @import("resources/Meshes3D.zig");
    test {
        std.testing.refAllDecls(@This());
    }
};

test {
    std.testing.refAllDecls(@This());
}
