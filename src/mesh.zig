const std = @import("std");
const root = @import("root.zig");
const vma_usage = root.vma_usage;
const AllocatedBuffer = vma_usage.AllocatedBuffer;
const checkVk = root.vulkan_init.checkVk;
const m3d = @import("math3d.zig");
const c = @import("clibs.zig");
const vk = c.vk;

const Vec2 = m3d.Vec2;
const Vec3 = m3d.Vec3;

pub const VertexInputDescription = struct {
    bindings: []const c.vk.VertexInputBindingDescription,
    attributes: []const c.vk.VertexInputAttributeDescription,

    flags: c.vk.PipelineVertexInputStateCreateFlags = 0,
};

pub const Vertex2D = struct {
    position: Vec2,
    color: Vec3,
    tex_coord: Vec2,

    pub const vertex_input_description = VertexInputDescription{
        .bindings = &.{c.vk.VertexInputBindingDescription{
            .binding = 0,
            .stride = @sizeOf(@This()),
            .inputRate = c.vk.VERTEX_INPUT_RATE_VERTEX,
        }},

        .attributes = &.{
            c.vk.VertexInputAttributeDescription{
                .binding = 0,
                .location = 0,
                .format = c.vk.FORMAT_R32G32_SFLOAT,
                .offset = @offsetOf(@This(), "position"),
            },
            c.vk.VertexInputAttributeDescription{
                .binding = 0,
                .location = 1,
                .format = c.vk.FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(@This(), "color"),
            },
            c.vk.VertexInputAttributeDescription{
                .binding = 0,
                .location = 2,
                .format = c.vk.FORMAT_R32G32_SFLOAT,
                .offset = @offsetOf(@This(), "tex_coord"),
            },
        },
    };
};

pub const Mesh2D = struct {
    vertices: []Vertex2D,
    vertex_buffer: AllocatedBuffer = undefined,
    indices: []u16,
    index_buffer: AllocatedBuffer = undefined,

    pub fn upload(self: *@This(), vma_a: c.vma.Allocator, upload_ctx: *root.vulkan_init.UploadContext, device: root.vulkan_init.Device) void {
        const vert_alloc_size, const idx_alloc_size = .{
            self.vertices.len * @sizeOf(Vertex2D),
            self.indices.len * @sizeOf(u16),
        };

        const vert_staging_buffer, const idx_staging_buffer = stage_cpu: {
            const vert_ci = std.mem.zeroInit(c.vk.BufferCreateInfo, .{
                .sType = c.vk.STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                .size = vert_alloc_size,
                .usage = c.vk.BUFFER_USAGE_TRANSFER_SRC_BIT,
            });
            const idx_ci = std.mem.zeroInit(c.vk.BufferCreateInfo, .{
                .sType = c.vk.STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                .size = idx_alloc_size,
                .usage = c.vk.BUFFER_USAGE_TRANSFER_SRC_BIT,
            });

            const ai = std.mem.zeroInit(c.vma.AllocationCreateInfo, .{
                .usage = c.vma.MEMORY_USAGE_CPU_ONLY,
            });

            var vert_buf: vma_usage.AllocatedBuffer = undefined;
            checkVk(c.vma.CreateBuffer(vma_a, &vert_ci, &ai, &vert_buf.buffer, &vert_buf.allocation, null)) catch @panic("Failed to create vertex buffer");
            var idx_buf: vma_usage.AllocatedBuffer = undefined;
            checkVk(c.vma.CreateBuffer(vma_a, &idx_ci, &ai, &idx_buf.buffer, &idx_buf.allocation, null)) catch @panic("Failed to create index buffer");
            break :stage_cpu .{ vert_buf, idx_buf };
        };
        defer {
            c.vma.DestroyBuffer(vma_a, vert_staging_buffer.buffer, vert_staging_buffer.allocation);
            c.vma.DestroyBuffer(vma_a, idx_staging_buffer.buffer, idx_staging_buffer.allocation);
        }

        // mapping memory
        {
            var data: ?*anyopaque = undefined;
            checkVk(c.vma.MapMemory(vma_a, vert_staging_buffer.allocation, &data)) catch @panic("failed to map memory");
            defer c.vma.UnmapMemory(vma_a, vert_staging_buffer.allocation);

            const vert_aligned_data: [*]Vertex2D = @ptrCast(@alignCast(data));
            @memcpy(vert_aligned_data, self.vertices);

            data = undefined;
            checkVk(c.vma.MapMemory(vma_a, idx_staging_buffer.allocation, &data)) catch @panic("failed to map memory");
            defer c.vma.UnmapMemory(vma_a, idx_staging_buffer.allocation);

            const idx_aligned_data: [*]u16 = @ptrCast(@alignCast(data));
            @memcpy(idx_aligned_data, self.indices);
        }

        // gpu allocation
        {
            const vert_ci = vk.BufferCreateInfo{
                .sType = vk.STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                .size = vert_alloc_size,
                .usage = vk.BUFFER_USAGE_VERTEX_BUFFER_BIT | c.vk.BUFFER_USAGE_TRANSFER_DST_BIT,
            };
            const idx_ci = vk.BufferCreateInfo{
                .sType = vk.STRUCTURE_TYPE_BUFFER_CREATE_INFO,
                .size = idx_alloc_size,
                .usage = vk.BUFFER_USAGE_INDEX_BUFFER_BIT | c.vk.BUFFER_USAGE_TRANSFER_DST_BIT,
            };

            const ai = c.vma.AllocationCreateInfo{
                .usage = c.vma.MEMORY_USAGE_GPU_ONLY,
            };

            checkVk(c.vma.CreateBuffer(vma_a, &vert_ci, &ai, &self.vertex_buffer.buffer, &self.vertex_buffer.allocation, null)) catch @panic("Failed to create vertex buffer");
            checkVk(c.vma.CreateBuffer(vma_a, &idx_ci, &ai, &self.index_buffer.buffer, &self.index_buffer.allocation, null)) catch @panic("Failed to create index buffer");
        }

        const SubmitCtx =
            struct {
                mesh_buffer: c.vk.Buffer,
                staging_buffer: c.vk.Buffer,
                size: usize,

                pub fn submit(ctx: @This(), cmd: c.vk.CommandBuffer) void {
                    const copy_region = c.vk.BufferCopy{
                        .size = ctx.size,
                    };
                    c.vk.CmdCopyBuffer(cmd, ctx.staging_buffer, ctx.mesh_buffer, 1, &copy_region);
                }
            };

        upload_ctx.immediateSubmit(device, SubmitCtx{
            .mesh_buffer = self.vertex_buffer.buffer,
            .staging_buffer = vert_staging_buffer.buffer,
            .size = vert_alloc_size,
        });

        upload_ctx.immediateSubmit(device, SubmitCtx{
            .mesh_buffer = self.index_buffer.buffer,
            .staging_buffer = idx_staging_buffer.buffer,
            .size = idx_alloc_size,
        });
    }
};

pub const Vertex3D = struct {
    position: Vec3,
    normal: Vec3,
    color: Vec3,
    uv: Vec2,

    pub const vertex_input_description = VertexInputDescription{
        .bindings = &.{
            std.mem.zeroInit(c.vk.VertexInputBindingDescription, .{
                .binding = 0,
                .stride = @sizeOf(Vertex3D),
                .inputRate = c.vk.VERTEX_INPUT_RATE_VERTEX,
            }),
        },
        .attributes = &.{
            std.mem.zeroInit(c.vk.VertexInputAttributeDescription, .{
                .location = 0,
                .binding = 0,
                .format = c.vk.FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(Vertex3D, "position"),
            }),
            std.mem.zeroInit(c.vk.VertexInputAttributeDescription, .{
                .location = 1,
                .binding = 0,
                .format = c.vk.FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(Vertex3D, "normal"),
            }),
            std.mem.zeroInit(c.vk.VertexInputAttributeDescription, .{
                .location = 2,
                .binding = 0,
                .format = c.vk.FORMAT_R32G32B32_SFLOAT,
                .offset = @offsetOf(Vertex3D, "color"),
            }),
            std.mem.zeroInit(c.vk.VertexInputAttributeDescription, .{
                .location = 3,
                .binding = 0,
                .format = c.vk.FORMAT_R32G32_SFLOAT,
                .offset = @offsetOf(Vertex3D, "uv"),
            }),
        },
    };
};

pub const Mesh3D = struct {
    vertices: []Vertex3D,
    vertex_buffer: AllocatedBuffer = undefined,
};

const obj_loader = @import("obj_loader.zig");

pub fn load_from_obj(a: std.mem.Allocator, filepath: []const u8) Mesh3D {
    var obj_mesh = obj_loader.parse_file(a, filepath) catch |err| {
        std.log.err("Failed to load obj file: {s}", .{@errorName(err)});
        unreachable;
    };
    defer obj_mesh.deinit();

    var vertices = std.ArrayList(Vertex3D){};

    for (obj_mesh.objects) |object| {
        var index_count: usize = 0;
        for (object.face_vertices) |face_vx_count| {
            if (face_vx_count < 3) {
                @panic("Face has fewer than 3 vertices. Not a valid polygon.");
            }

            for (0..face_vx_count) |vx_index| {
                const obj_index = object.indices[index_count];
                const pos = obj_mesh.vertices[obj_index.vertex];
                const nml = obj_mesh.normals[obj_index.normal];
                const uvs = obj_mesh.uvs[obj_index.uv];

                const vx = Vertex3D{
                    .position = Vec3.make(pos[0], pos[1], pos[2]),
                    .normal = Vec3.make(nml[0], nml[1], nml[2]),
                    .color = Vec3.make(nml[0], nml[1], nml[2]),
                    .uv = Vec2.make(uvs[0], 1.0 - uvs[1]),
                };

                // Triangulate the polygon
                if (vx_index > 2) {
                    const v0 = vertices.items[vertices.items.len - 3];
                    const v1 = vertices.items[vertices.items.len - 1];
                    vertices.append(a, v0) catch @panic("OOM");
                    vertices.append(a, v1) catch @panic("OOM");
                }

                vertices.append(a, vx) catch @panic("OOM");

                index_count += 1;
            }
        }
    }

    return Mesh3D{
        .vertices = vertices.toOwnedSlice(a) catch @panic("Failed to make owned slice"),
    };
}
