const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Feature Flags ──────────────────────────────────────────────
    const enable_cuda = b.option(bool, "enable_cuda", "Enable CUDA GPU acceleration") orelse false;
    const enable_pipewire = b.option(bool, "pipewire", "Enable PipeWire audio backend") orelse false;
    const enable_jack = b.option(bool, "jack", "Enable JACK audio backend") orelse false;

    const options = b.addOptions();
    options.addOption(bool, "enable_cuda", enable_cuda);
    options.addOption(bool, "enable_pipewire", enable_pipewire);
    options.addOption(bool, "enable_jack", enable_jack);

    // ── Target 1: Standalone executable ────────────────────────────
    const exe = b.addExecutable(.{
        .name = "worldsynth",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addOptions("build_options", options);
    b.installArtifact(exe);

    // ── Target 2: CLAP plugin (shared library) ─────────────────────
    // Source files added in WP-032+ (Sprint 2)
    const plugin_step = b.step("plugin", "Build CLAP plugin (.clap)");
    _ = plugin_step;

    // ── Target 3: Benchmarks ───────────────────────────────────────
    // Benchmark harness added in later WPs
    const bench_step = b.step("bench", "Build and run benchmarks");
    _ = bench_step;

    // ── Tests ──────────────────────────────────────────────────────
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.root_module.addOptions("build_options", options);

    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
