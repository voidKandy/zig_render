const std = @import("std");
const core = @import("../root.zig");
const vk = core.clibs.vk;
const checkVk = core.bindings.vulkan_init.checkVk;

/// Shaders are compiled into the library, this is how we access them from within the library
pub fn createShaderModule(comptime path: []const u8, device: vk.Device, alloc_cbs: ?*vk.AllocationCallbacks) ?vk.ShaderModule {
    const bytes align(4) = @embedFile(path);
    std.debug.assert(bytes.len % 4 == 0);
    // NOTE: This being a better language than C/C++, means we don´t need to load
    // the SPIR-V code from a file, we can just embed it as an array of bytes.
    // To reflect the different behaviour from the original code, we also changed
    // the function name.

    const data: *const u32 = @ptrCast(@alignCast(bytes.ptr));

    const shader_module_ci = std.mem.zeroInit(vk.ShaderModuleCreateInfo, .{
        .sType = vk.STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = bytes.len,
        .pCode = data,
    });

    var shader_module: vk.ShaderModule = undefined;
    checkVk(vk.CreateShaderModule(device, &shader_module_ci, alloc_cbs, &shader_module)) catch |err| {
        std.log.err("Failed to create shader module with error: {s}", .{@errorName(err)});
        return null;
    };

    return shader_module;
}
