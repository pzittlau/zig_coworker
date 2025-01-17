const std = @import("std");
const CoWorker = @import("CoWorker.zig");

test {
    std.testing.refAllDeclsRecursive(CoWorker);
}
