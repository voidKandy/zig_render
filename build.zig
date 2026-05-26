const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const core_lib = b.addModule("core", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    core_lib.linkSystemLibrary("SDL3", .{});
    core_lib.linkSystemLibrary("vulkan", .{});
    const env_map = try std.process.getEnvMap(b.allocator);
    if (env_map.get("VK_SDK_PATH")) |path| {
        core_lib.addLibraryPath(.{ .cwd_relative = std.fmt.allocPrint(b.allocator, "{s}/lib", .{path}) catch @panic("OOM") });
        core_lib.addIncludePath(.{ .cwd_relative = std.fmt.allocPrint(b.allocator, "{s}/include", .{path}) catch @panic("OOM") });
    }
    core_lib.addCSourceFile(.{ .file = b.path("src/vk_mem_alloc.cpp"), .flags = &.{""} });
    core_lib.addIncludePath(b.path("libs/vma/"));
    core_lib.addIncludePath(b.path("libs/stb/"));
    core_lib.addIncludePath(b.path("libs/imgui/"));
    core_lib.addIncludePath(b.path("libs/tinyobjloader/"));
    core_lib.addCSourceFile(.{ .file = b.path("src/stb_image.c"), .flags = &.{""} });

    addAllShaders(b, core_lib);

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
    imgui_lib.linkLibCpp();
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

    core_lib.linkLibrary(imgui_lib);

    const exe_tests = b.addTest(.{
        .root_module = core_lib,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    // test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    buildBinaries(b, target, optimize, &[_]struct { []const u8, *std.Build.Module }{
        .{ "core", core_lib },
    });
}

const BINARIES_PATH = "bins";
fn buildBinaries(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    opt: std.builtin.OptimizeMode,
    imports: []const struct { []const u8, *std.Build.Module },
) void {
    const dir = std.fs.cwd().openDir(BINARIES_PATH, .{}) catch @panic("Failed to get directory");
    var buffer: [256]u8 = undefined;
    @memset(&buffer, 0);
    var fba = std.heap.FixedBufferAllocator.init(&buffer);
    var iter = dir.iterate();
    while (iter.next() catch |e| std.debug.panic("Dir iterator failure: {}\n", .{e})) |f| {
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

        exe.linkLibCpp();
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
    lib: *std.Build.Module,
) void {
    const shaders_dir = if (@hasDecl(@TypeOf(b.build_root.handle), "openIterableDir"))
        b.build_root.handle.openIterableDir(SHADERS_PATH, .{}) catch @panic("Failed to open shaders directory")
    else
        b.build_root.handle.openDir(SHADERS_PATH, .{ .iterate = true }) catch @panic("Failed to open shaders directory");

    var file_it = shaders_dir.iterate();
    while (file_it.next() catch @panic("Failed to iterate shader directory")) |entry| {
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
