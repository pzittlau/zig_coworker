//! This module provides an implementation for stackful, symmetric, cooperative coroutines.
//!
//! These coroutines, or "CoWorkers", allow for manual switching of execution contexts without
//! relying on a central scheduler. This can be useful for scenarios requiring fine-grained control
//! over concurrency.

const std = @import("std");

threadlocal var thread_state: ThreadState = .{};

const StackPtr = [*]u8;

/// Represents errors that can occur during CoWorker operations.
pub const CoWorkerError = error{
    /// Indicates that the provided stack was too small to initialize a CoWorker.
    StackOverflow,
};

extern fn swap_stacks(from: *StackPtr, to: *StackPtr) void;
comptime {
    asm (
        \\ .global swap_stacks
        \\ swap_stacks:
        \\ pushq %rbp
        \\ pushq %rbx
        \\ pushq %r12
        \\ pushq %r13
        \\ pushq %r14
        \\ pushq %r15
        \\
        \\ # Swap stack
        \\ movq %rsp, (%rdi)
        \\ movq (%rsi), %rsp
        \\
        \\ popq %r15
        \\ popq %r14
        \\ popq %r13
        \\ popq %r12
        \\ popq %rbx
        \\ popq %rbp
        \\
        \\ retq
    );
}

const ThreadState = struct {
    coworker_root: CoWorker = .{
        .func = undefined,
        .stack = undefined,
        .stack_ptr = undefined,
    },
    coworker_current: ?*CoWorker = null,

    /// Switches execution from the current CoWorker to the provided CoWorker.
    ///
    /// This function saves the current stack pointer and restores the stack pointer of the target
    /// CoWorker, effectively transferring control.
    fn switchTo(self: *@This(), to: *CoWorker) void {
        const from = self.current();
        if (from == to) return;
        self.coworker_current = to;
        swap_stacks(&from.stack_ptr, &to.stack_ptr);
    }

    /// Returns a pointer to the currently executing CoWorker.
    ///
    /// If no CoWorker is currently active (i.e., at the start of the program), it returns a pointer
    /// to the root CoWorker, which represents the initial execution context.
    fn current(self: *@This()) *CoWorker {
        return self.coworker_current orelse &self.coworker_root;
    }

    /// Returns true if the current execution is within a CoWorker (not the root).
    fn inCoWorker(self: *@This()) bool {
        return self.current() != &self.coworker_root;
    }
};

/// Represents a cooperative worker with its own stack.
///
/// CoWorkers allow for concurrent execution by explicitly switching control between them. They are
/// stackful, meaning each CoWorker has its own call stack.
/// The CoWorker struct itself is also placed on the provided stack.
pub const CoWorker = struct {
    /// The function that this CoWorker will execute.
    func: *const fn () void,
    /// The memory allocated for this CoWorker's stack.
    stack: []u8,
    /// Indicates whether this CoWorker owns the allocated stack memory.
    owns_stack: bool = false,
    /// The current stack pointer for this CoWorker.
    stack_ptr: StackPtr,

    const alignment = 16; // 16 byte aligned per x86-64 ABI
    const save_bytes = 8 * @sizeOf(usize);
    const jump_offset = 6 * @sizeOf(usize);
    const Trampoline = @TypeOf(&trampoline);

    /// Initializes a new CoWorker with a newly allocated stack.
    ///
    /// The `allocator` is used to allocate the stack memory. The `stack_size` specifies the size
    /// of the stack in bytes. The `func` is the function that the CoWorker will execute when it's
    /// switched to.
    /// The CoWorker struct itself is also placed on the provided stack.
    pub fn init(allocator: std.mem.Allocator, stack_size: u64, func: *const fn () void) !*CoWorker {
        const stack = try allocator.alloc(u8, stack_size);
        errdefer allocator.free(stack);
        return initInternal(func, stack, true);
    }

    /// Initializes a new CoWorker using a provided stack.
    ///
    /// This is useful when you want to manage the stack allocation yourself. The `stack` slice
    /// represents the memory to be used as the CoWorker's stack. The `func` is the function that
    /// the CoWorker will execute.
    pub fn initFromStack(stack: []u8, func: *const fn () void) !*CoWorker {
        return initInternal(func, stack, false);
    }

    fn initInternal(func: *const fn () void, stack: []u8, owns_stack: bool) !*CoWorker {
        if (stack.len <= @sizeOf(CoWorker) + save_bytes) {
            return CoWorkerError.StackOverflow;
        }

        const stack_ptr_int = std.mem.alignBackward(
            usize,
            @intFromPtr(stack.ptr + stack.len - @sizeOf(CoWorker)),
            alignment,
        );
        const coworker: *CoWorker = @ptrFromInt(stack_ptr_int);
        var stack_ptr: [*]u8 = @ptrFromInt(stack_ptr_int);

        stack_ptr -= save_bytes;
        const trampoline_ptr: *Trampoline = @ptrCast(@alignCast(stack_ptr + jump_offset));
        trampoline_ptr.* = &trampoline;

        coworker.* = @This(){
            .func = func,
            .stack_ptr = stack_ptr,
            .stack = stack,
            .owns_stack = owns_stack,
        };
        return coworker;
    }

    fn trampoline(_: *StackPtr, stack_ptr: *StackPtr) callconv(.C) noreturn {
        // WARNING: the first parameter can't be removed with the current implementation because
        // then it segfaults. I don't know why.
        const coworker: *CoWorker = @fieldParentPtr("stack_ptr", stack_ptr);
        coworker.func();
        @panic("A coworker may never return.");
    }

    /// Deinitializes the CoWorker, freeing the stack if it was allocated by this CoWorker.
    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        if (self.owns_stack) {
            allocator.free(self.stack);
        }
    }

    /// Switches execution to this CoWorker.
    ///
    /// This function transfers control from the currently running CoWorker to this CoWorker.
    pub fn switchTo(self: *CoWorker) void {
        // OPTIM: should we inline this?
        thread_state.switchTo(self);
    }

    /// Returns a pointer to the currently executing CoWorker.
    pub fn current() *CoWorker {
        return thread_state.current();
    }

    /// Returns true if the current execution is within a CoWorker (not the root).
    pub fn inCoWorker() bool {
        return thread_state.inCoWorker();
    }
};

var test_cowo_root: *CoWorker = undefined;

fn testBasic() void {
    test_basic += 1;
    test_cowo_root.switchTo();
    test_basic += 1;
    test_cowo_root.switchTo();
}

var test_basic: u64 = 0;

test "basic" {
    const stack = try std.testing.allocator.alloc(u8, 1024);
    defer std.testing.allocator.free(stack);

    test_cowo_root = thread_state.current();
    const test_cowo = try CoWorker.initFromStack(stack, testBasic);

    test_cowo.switchTo();
    try std.testing.expectEqual(1, test_basic);
    test_cowo.switchTo();
    try std.testing.expectEqual(2, test_basic);
}

test "small_stack" {
    try std.testing.expectError(
        CoWorkerError.StackOverflow,
        CoWorker.init(std.testing.allocator, 16, testBasic),
    );
}

var test_cowo_a: *CoWorker = undefined;
var test_cowo_b: *CoWorker = undefined;

fn testCoWorkerA() void {
    for (0..5) |i| {
        std.debug.print("CoWorker A: {}\n", .{i});
        thread_state.switchTo(test_cowo_b);
    }
    std.debug.print("CoWorker A: finished\n", .{});
    thread_state.switchTo(test_cowo_b);
}

fn testCoWorkerB() void {
    for (0..5) |i| {
        std.debug.print("CoWorker B: {}\n", .{i});
        thread_state.switchTo(test_cowo_a);
    }
    std.debug.print("CoWorker B: finished\n", .{});
    thread_state.switchTo(test_cowo_root);
}

test "multiple_cowos" {
    const stack_size: usize = 1024 * 4;

    test_cowo_root = thread_state.current();
    test_cowo_a = try CoWorker.init(std.testing.allocator, stack_size, testCoWorkerA);
    defer test_cowo_a.deinit(std.testing.allocator);
    test_cowo_b = try CoWorker.init(std.testing.allocator, stack_size, testCoWorkerB);
    defer test_cowo_b.deinit(std.testing.allocator);

    thread_state.switchTo(test_cowo_a);
    std.debug.print("CoWorker Root finished\n", .{});
}

var test_cowo_bench: *CoWorker = undefined;
fn test_bench_cowo() void {
    while (true) {
        test_cowo_root.switchTo();
    }
}

test "benchmark" {
    const iterations = 10_000_000;

    test_cowo_root = thread_state.current();
    const bench_cowo = try CoWorker.init(std.testing.allocator, 1024, test_bench_cowo);
    defer bench_cowo.deinit(std.testing.allocator);

    // Warmup
    for (0..100_000) |_| {
        bench_cowo.switchTo();
    }

    const start = std.time.nanoTimestamp();
    for (0..iterations) |_| {
        bench_cowo.switchTo();
    }
    const end = std.time.nanoTimestamp();

    const time = end - start;
    std.debug.print(
        "Avg. per CoWorker switch: {d:.2}ns\n",
        .{@as(f64, @floatFromInt(time)) / @as(f64, @floatFromInt(iterations * 2))},
    );
}

fn testPanic() void {
    test_cowo_root.switchTo();
    test_cowo_root.switchTo();
}

test "panic" {
    test_cowo_root = thread_state.current();
    const cowo = try CoWorker.init(std.testing.allocator, 1024, testPanic);
    defer cowo.deinit(std.testing.allocator);

    cowo.switchTo();
    cowo.switchTo();
    // If this gets uncommented it should panic
    // cowo.switchTo();
}
