const std = @import("std");
pub const CoWorker = @import("CoWorker.zig");

test {
    std.testing.refAllDeclsRecursive(CoWorker);
}
