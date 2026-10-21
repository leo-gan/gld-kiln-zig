const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const kiln = b.addModule("kiln", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "gld-kilngen-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "kiln", .module = kiln },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the Kiln generator");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const bench_exe = b.addExecutable(.{
        .name = "kiln-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "kiln", .module = kiln },
            },
        }),
    });
    const example = b.addExecutable(.{
        .name = "kiln-roundtrip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/roundtrip.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "kiln", .module = kiln },
            },
        }),
    });
    const example_step = b.step("example", "Run the round-trip example");
    const example_run = b.addRunArtifact(example);
    example_step.dependOn(&example_run.step);

    const bench_step = b.step("bench", "Run the encode and decode microbench");
    const bench_run = b.addRunArtifact(bench_exe);
    bench_step.dependOn(&bench_run.step);

    const tests = b.addTest(.{
        .root_module = kiln,
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
