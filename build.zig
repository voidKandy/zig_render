const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    var threaded: std.Io.Threaded = .init(b.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const env_map = std.process.Environ.Map.init(b.allocator);
    // const env_map = try std.process.getEnvMap(b.allocator);
    const translate_c = b.addTranslateC(.{
        .root_source_file = b.path("src/clibs/c.h"),
        .target = target,
        .optimize = optimize,
    });
    translate_c.linkSystemLibrary("SDL3", .{});
    translate_c.linkSystemLibrary("vulkan", .{});
    translate_c.addIncludePath(b.path("libs/vma"));
    translate_c.addIncludePath(b.path("libs/stb"));
    translate_c.addIncludePath(b.path("libs/imgui"));
    translate_c.addIncludePath(b.path("libs/box3d/include/box3d"));
    // translate_c.linkSystemLibrary("vk_mem_alloc", .{});
    // translate_c.linkSystemLibrary("stb_image", .{});
    // translate_c.linkSystemLibrary("cimgui", .{});

    const c_module = translate_c.createModule();

    const core_lib = b.addModule("core", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{
                .name = "c",
                .module = c_module,
            },
        },
    });
    if (env_map.get("VK_SDK_PATH")) |path| {
        core_lib.addLibraryPath(.{ .cwd_relative = std.fmt.allocPrint(b.allocator, "{s}/lib", .{path}) catch @panic("OOM") });
        core_lib.addIncludePath(.{ .cwd_relative = std.fmt.allocPrint(b.allocator, "{s}/include", .{path}) catch @panic("OOM") });
    }

    core_lib.linkSystemLibrary("SDL3", .{});
    core_lib.linkSystemLibrary("vulkan", .{});
    core_lib.addCSourceFile(.{ .file = b.path("src/clibs/vk_mem_alloc.cpp"), .flags = &.{""} });
    core_lib.addIncludePath(b.path("libs/vma/"));
    core_lib.addIncludePath(b.path("libs/stb/"));
    core_lib.addIncludePath(b.path("libs/imgui/"));
    core_lib.addIncludePath(b.path("libs/box3d/"));
    core_lib.addCSourceFile(.{ .file = b.path("src/clibs/stb_image.c"), .flags = &.{""} });

    addAllShaders(b, io, core_lib);

    const imgui_lib = buildImgui(b, target, optimize);
    core_lib.linkLibrary(imgui_lib);

    const box3d_lib = buildBox3D(b, target, optimize);
    core_lib.linkLibrary(box3d_lib);

    const exe_tests = b.addTest(.{
        .root_module = core_lib,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);

    buildBinaries(
        b,
        io,
        target,
        optimize,
        &[_]struct { []const u8, *std.Build.Module }{
            .{ "core", core_lib },
        },
    );
}

fn buildImgui(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const imgui_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "cimgui",
        .root_module = b.addModule("cimgui", .{
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
        }),
    });
    imgui_lib.root_module.addIncludePath(b.path("libs/imgui/"));
    imgui_lib.root_module.addIncludePath(b.path("libs/sdl3/include/"));
    imgui_lib.root_module.linkSystemLibrary("vulkan", .{});
    imgui_lib.root_module.link_libcpp = true;
    imgui_lib.root_module.addCSourceFiles(.{
        .files = &.{
            "libs/imgui/imgui.cpp",
            "libs/imgui/imgui_demo.cpp",
            "libs/imgui/imgui_draw.cpp",
            "libs/imgui/imgui_tables.cpp",
            "libs/imgui/imgui_widgets.cpp",
            "libs/imgui/imgui_impl_sdl3.cpp",
            "libs/imgui/imgui_impl_vulkan.cpp",
            "libs/imgui/cimgui.cpp",
            "libs/imgui/cimgui_impl_sdl3.cpp",
            "libs/imgui/cimgui_impl_vulkan.cpp",
        },
    });
    return imgui_lib;
}

fn buildBox3D(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const box3d_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "box3d",
        .root_module = b.addModule("box3d", .{
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
        }),
    });

    box3d_lib.root_module.addIncludePath(b.path("libs/box3d/include"));
    // src/ also needs to be on the include path — box3d's own .c files
    // #include internal headers like "core.h" relative to src/, not include/
    box3d_lib.root_module.addIncludePath(b.path("libs/box3d/src"));
    box3d_lib.root_module.link_libc = true;

    box3d_lib.root_module.addCSourceFiles(.{
        .files = &.{
            "libs/box3d/src/aabb.c",
            "libs/box3d/src/arena_allocator.c",
            "libs/box3d/src/bitset.c",
            "libs/box3d/src/block_allocator.c",
            "libs/box3d/src/body.c",
            "libs/box3d/src/broad_phase.c",
            "libs/box3d/src/capsule.c",
            "libs/box3d/src/compound.c",
            "libs/box3d/src/constraint_graph.c",
            "libs/box3d/src/contact_solver.c",
            "libs/box3d/src/contact.c",
            "libs/box3d/src/convex_manifold.c",
            "libs/box3d/src/core.c",
            "libs/box3d/src/distance_joint.c",
            "libs/box3d/src/distance.c",
            "libs/box3d/src/dynamic_tree.c",
            "libs/box3d/src/height_field.c",
            "libs/box3d/src/hull.c",
            "libs/box3d/src/id_pool.c",
            "libs/box3d/src/island.c",
            "libs/box3d/src/joint.c",
            "libs/box3d/src/manifold.c",
            "libs/box3d/src/math_functions.c",
            "libs/box3d/src/mesh_contact.c",
            "libs/box3d/src/mesh.c",
            "libs/box3d/src/motor_joint.c",
            "libs/box3d/src/mover.c",
            "libs/box3d/src/name_cache.c",
            "libs/box3d/src/parallel_for.c",
            "libs/box3d/src/parallel_joint.c",
            "libs/box3d/src/physics_world.c",
            "libs/box3d/src/prismatic_joint.c",
            "libs/box3d/src/recording_replay.c",
            "libs/box3d/src/recording.c",
            "libs/box3d/src/revolute_joint.c",
            "libs/box3d/src/scheduler.c",
            "libs/box3d/src/sensor.c",
            "libs/box3d/src/shape.c",
            "libs/box3d/src/simd.c",
            "libs/box3d/src/solver_set.c",
            "libs/box3d/src/solver.c",
            "libs/box3d/src/sphere.c",
            "libs/box3d/src/spherical_joint.c",
            "libs/box3d/src/table.c",
            "libs/box3d/src/timer.c",
            "libs/box3d/src/triangle_manifold.c",
            "libs/box3d/src/types.c",
            "libs/box3d/src/weld_joint.c",
            "libs/box3d/src/wheel_joint.c",
            "libs/box3d/src/world_snapshot.c",
        },
        .flags = &.{
            "-ffp-contract=off", // matches their determinism flag from CMakeLists.txt
        },
    });

    return box3d_lib;
}

const BINARIES_PATH = "bins";
fn buildBinaries(
    b: *std.Build,
    io: std.Io,
    target: std.Build.ResolvedTarget,
    opt: std.builtin.OptimizeMode,
    imports: []const struct { []const u8, *std.Build.Module },
) void {
    const dir = std.Io.Dir.cwd().openDir(io, BINARIES_PATH, .{}) catch @panic("Failed to get directory");
    var buffer: [256]u8 = undefined;
    @memset(&buffer, 0);
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var iter = dir.iterate();
    while (iter.next(io) catch |e| std.debug.panic("Dir iterator failure: {}\n", .{e})) |f| {
        const name = name: {
            var split = std.mem.splitBackwardsScalar(u8, f.name, '.');
            _ = split.first();
            break :name split.next() orelse @panic("malformed test file name");
        };

        const fullpath = std.fmt.allocPrint(fba.allocator(), "{s}/{s}", .{ BINARIES_PATH, f.name }) catch |e| std.debug.panic("Failed to get full path: {}\n", .{e});
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(fullpath),
                .target = target,
                .optimize = opt,
            }),
        });
        exe.root_module.link_libcpp = true;
        // exe.linkLibCpp();
        for (imports) |import|
            exe.root_module.addImport(import.@"0", import.@"1");

        b.installArtifact(exe);
        const run = b.addRunArtifact(exe);
        const step = b.step(name, f.name);
        step.dependOn(&run.step);

        if (b.args) |args| {
            run.addArgs(args);
        }
    }
}

const SHADERS_PATH = "shaders";

fn addAllShaders(
    b: *std.Build,
    io: std.Io,
    lib: *std.Build.Module,
) void {
    const shaders_dir = if (@hasDecl(@TypeOf(b.build_root.handle), "openIterableDir"))
        b.build_root.handle.openIterableDir(io, SHADERS_PATH, .{}) catch @panic("Failed to open shaders directory")
    else
        b.build_root.handle.openDir(io, SHADERS_PATH, .{ .iterate = true }) catch @panic("Failed to open shaders directory");

    var file_it = shaders_dir.iterate();
    while (file_it.next(io) catch @panic("Failed to iterate shader directory")) |entry| {
        if (entry.kind == .file) {
            if (entry.name[0] == '.') continue;
            const ext = std.fs.path.extension(entry.name);
            if (std.mem.eql(u8, ext, ".glsl")) {
                const basename = std.fs.path.basename(entry.name);
                const name = basename[0 .. basename.len - ext.len];

                std.debug.print("Found shader file to compile: {s}. Compiling with name: {s}\n", .{ entry.name, name });
                addShader(b, lib, name);
            }
        }
    }
}

fn addShader(
    b: *std.Build,
    lib: *std.Build.Module,
    name: []const u8,
) void {
    const source = std.fmt.allocPrint(b.allocator, SHADERS_PATH ++ "/{s}.glsl", .{name}) catch @panic("OOM");
    const outpath = std.fmt.allocPrint(b.allocator, SHADERS_PATH ++ "/{s}.spv", .{name}) catch @panic("OOM");

    const shader_compilation = b.addSystemCommand(&.{"glslangValidator"});
    // this allows shader compilation errors to be printed to stdout
    shader_compilation.stdio = .inherit;
    shader_compilation.addArg("-V");
    shader_compilation.addArg("-o");
    const output = shader_compilation.addOutputFileArg(outpath);
    shader_compilation.addFileArg(b.path(source));

    lib.addAnonymousImport(name, .{ .root_source_file = output });
}
