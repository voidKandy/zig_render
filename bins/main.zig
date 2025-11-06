const std = @import("std");
const log = std.log;
const core = @import("core");
const vulkan_init = core.vulkan_init;
const c = core.clibs;
const vk = c.vk;
const checkVk = vulkan_init.checkVk;
const sdl = c.sdl;
const VkError = core.vulkan_init.VkError;

pub fn main() void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer if (gpa.deinit() == .leak) {
        @panic("Leaked memory");
    };

    var cwd_buff: [1024]u8 = undefined;
    const cwd = std.process.getCwd(cwd_buff[0..]) catch @panic("cwd_buff too small");
    std.log.info("Running from: {s}", .{cwd});

    var engine = core.VulkanEngine.init(gpa.allocator());
    defer engine.deinit();

    engine.run();
}
