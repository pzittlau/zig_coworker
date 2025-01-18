# Zig CoWorker

This project provides a simple implementation of symmetric, cooperative, stackful coroutines in Zig,
without relying on a central scheduler. It allows you to create multiple execution contexts 
(CoWorkers) that can explicitly switch control between each other. This approach is useful for 
concurrent programming where you want fine-grained control over when and how execution switches 
occur.

**Key Features:**

*   **Symmetric Coroutines:** Any coroutine can transfer control to any other coroutine.
*   **Cooperative Multitasking:** Coroutines explicitly yield control, preventing preemption.
*   **Stackful Coroutines:** Each coroutine has its own stack, allowing it to execute arbitrary 
    code, including function calls.
*   **No Scheduler:** Switching coroutines is done explicitly by calling a `switchTo` function.

**Example:**

The following example demonstrates how to create and switch between two CoWorkers:

```zig
const std = @import("std");
const CoWorker = @import("src/CoWorker.zig");

var test_cowo_root: *CoWorker = undefined;
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

pub fn main() !void {
    const stack_size: usize = 1024 * 4;
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    threadlocal var thread_state: CoWorker.ThreadState = .{};
    test_cowo_root = thread_state.current();
    test_cowo_a = try CoWorker.init(allocator, stack_size, testCoWorkerA);
    defer test_cowo_a.deinit(allocator);
    test_cowo_b = try CoWorker.init(allocator, stack_size, testCoWorkerB);
    defer test_cowo_b.deinit(allocator);

    thread_state.switchTo(test_cowo_a);
    std.debug.print("CoWorker Root finished\n", .{});
}
```

In this example, testCoWorkerA and testCoWorkerB are two separate coroutines. They repeatedly print
a message and then switch control to the other coroutine. The main function initializes the 
coroutines and starts the execution by switching to testCoWorkerA.

How to Use:

- Include `CoWorker.zig` in your Zig project.
- Create `CoWorker` instances using `CoWorker.init` (allocating a new stack) or 
  `CoWorker.initFromStack` (using a provided stack).
- Use the `switchTo` method to transfer control to another `CoWorker`.
- Remember that `CoWorker`s must explicitly yield control; there is no automatic scheduling.
