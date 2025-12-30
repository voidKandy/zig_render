const tol = @import("clibs.zig").tol;

pub const TolError = error{
    Empty,
    InvalidParameter,
    FileOperation,
};

pub fn checkTol(result: c_int) TolError!void {
    return switch (result) {
        tol.SUCCESS => {},
        tol.ERROR_EMPTY => TolError.Empty,
        tol.ERROR_INVALID_PARAMETER => TolError.InvalidParameter,
        tol.ERROR_FILE_OPERATION => TolError.FileOperation,
        else => @panic(
            \\ Encountered unexpected Tiny Object Loader result
        ),
    };
}
