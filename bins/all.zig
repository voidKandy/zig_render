const std = @import("std");

pub fn main() void {
    std.debug.print("Hello from All bins!\n", .{});
}

test {
    std.testing.refAllDecls(@This());
}
