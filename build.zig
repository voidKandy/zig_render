const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const mod = b.addModule("zig_render", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // const exe = b.addExecutable(.{
    //     .name = "zig_render",
    //     .root_module = b.createModule(.{
    //         .root_source_file = b.path("src/main.zig"),
    //         .target = target,
    //         .optimize = optimize,
    //         .imports = &.{
    //             .{ .name = "zig_render", .module = mod },
    //         },
    //     }),
    // });
    const core_lib = b.addModule("core", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    core_lib.linkSystemLibrary("SDL3", .{});
    core_lib.linkSystemLibrary("vulkan", .{});

    // exe.addLibraryPath(.{ .cwd_relative = "libs/sdl3/lib" });
    // exe.addIncludePath(.{ .cwd_relative = "libs/sdl3/include" });
    const env_map = try std.process.getEnvMap(b.allocator);
    if (env_map.get("VK_SDK_PATH")) |path| {
        core_lib.addLibraryPath(.{ .cwd_relative = std.fmt.allocPrint(b.allocator, "{s}/lib", .{path}) catch @panic("OOM") });
        core_lib.addIncludePath(.{ .cwd_relative = std.fmt.allocPrint(b.allocator, "{s}/include", .{path}) catch @panic("OOM") });
    }
    core_lib.addCSourceFile(.{ .file = b.path("src/vk_mem_alloc.cpp"), .flags = &.{""} });
    core_lib.addIncludePath(b.path("libs/vma/"));
    core_lib.addIncludePath(b.path("libs/stb/"));
    core_lib.addIncludePath(b.path("libs/imgui/"));
    core_lib.addCSourceFile(.{ .file = b.path("src/stb_image.c"), .flags = &.{""} });

    compileAllShaders(b, core_lib);
    // core_lib.linkLibCpp();
    // b.installArtifact(exe);
    // b.installBinFile("libs/sdl3/lib/libSDL3.so", "libSDL3.so.0");
    // exe.root_module.addRPathSpecial("$ORIGIN");

    const imgui_lib = b.addLibrary(.{
        .linkage = .static,
        .name = "cimgui",
        .root_module = b.addModule("cimgui", .{
            .root_source_file = null,
            .target = target,
            .optimize = optimize,
        }),
    });
    // imgui_lib.root_module.linkSystemLibrary("vulkan", .{});
    // imgui_lib.root_module.linkSystemLibrary("SDL3", .{});
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

    // compileAllShaders(b, core_lib);

    // const run_step = b.step("run", "Run the app");
    // const run_cmd = b.addRunArtifact(exe);
    // run_step.dependOn(&run_cmd.step);
    // run_cmd.step.dependOn(b.getInstallStep());

    // if (b.args) |args| {
    //     run_cmd.addArgs(args);
    // }

    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{
        .root_module = core_lib,
    });

    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    buildBinaries(b, target, optimize, core_lib);
}

fn buildBinaries(b: *std.Build, target: std.Build.ResolvedTarget, opt: std.builtin.OptimizeMode, core_lib: *std.Build.Module) void {
    const bins_entry = b.path("bins/all.zig");
    const bins_dir = "bins";
    const dir = std.fs.cwd().openDir(bins_dir, .{}) catch |e| std.debug.panic("Failed to get directory {s}: {}\n", .{ bins_entry.src_path.sub_path, e });
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

        const fullpath = std.fmt.allocPrint(fba.allocator(), "{s}/{s}", .{ bins_dir, f.name }) catch |e| std.debug.panic("Failed to get full path: {}\n", .{e});
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(fullpath),
                .target = target,
                .optimize = opt,
            }),
        });

        exe.linkLibCpp();
        exe.root_module.addImport("core", core_lib);

        b.installArtifact(exe);
        const run = b.addRunArtifact(exe);
        const step = b.step(name, f.name);
        step.dependOn(&run.step);

        if (b.args) |args| {
            run.addArgs(args);
        }
    }
}

fn compileAllShaders(
    b: *std.Build,
    lib: *std.Build.Module,
    // exe: *std.Build.Step.Compile

) void {
    const shaders_dir = if (@hasDecl(@TypeOf(b.build_root.handle), "openIterableDir"))
        b.build_root.handle.openIterableDir("shaders", .{}) catch @panic("Failed to open shaders directory")
    else
        b.build_root.handle.openDir("shaders", .{ .iterate = true }) catch @panic("Failed to open shaders directory");

    var file_it = shaders_dir.iterate();
    while (file_it.next() catch @panic("Failed to iterate shader directory")) |entry| {
        if (entry.kind == .file) {
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
    // exe: *std.Build.Step.Compile,

    lib: *std.Build.Module,
    name: []const u8,
) void {
    const source = std.fmt.allocPrint(b.allocator, "shaders/{s}.glsl", .{name}) catch @panic("OOM");
    const outpath = std.fmt.allocPrint(b.allocator, "shaders/{s}.spv", .{name}) catch @panic("OOM");

    const shader_compilation = b.addSystemCommand(&.{"glslangValidator"});
    shader_compilation.addArg("-V");
    shader_compilation.addArg("-o");
    const output = shader_compilation.addOutputFileArg(outpath);
    shader_compilation.addFileArg(b.path(source));

    lib.addAnonymousImport(name, .{ .root_source_file = output });
}
