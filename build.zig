const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const ioctx_mod = b.createModule(.{
        .root_source_file = b.path("src/ioctx.zig"),
        .target = target,
    });

    const mod = b.addModule("cuteclaw", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "ioctx", .module = ioctx_mod },
        },
    });

    const exe = b.addExecutable(.{
        .name = "cuteclaw",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "cuteclaw", .module = mod },
                .{ .name = "ioctx", .module = ioctx_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run CuteClaw CLI");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    // Zig 0.17: arguments after `zig build run --` are passed through here.
    run_cmd.addPassthruArgs();

    // zig test 只分析真正被引用到的文件，所以测试根是 src/tests.zig：
    // 它显式引用全部源文件，让每个文件里的 test 块都能被收集执行。
    const test_mod = b.createModule(.{
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ioctx", .module = ioctx_mod },
        },
    });
    const test_exe = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(test_exe);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_exe_tests.step);


    const fmt_step = b.step("fmt", "zig fmt --check on src/");
    const fmt_cmd = b.addSystemCommand(&.{ "zig", "fmt", "--check", "src" });
    fmt_cmd.setCwd(b.path("."));
    fmt_step.dependOn(&fmt_cmd.step);
}

