const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Feature Flags ──────────────────────────────────────────────
    const enable_cuda = b.option(bool, "enable_cuda", "Enable CUDA GPU acceleration") orelse false;
    const enable_tensorrt = b.option(bool, "enable_tensorrt", "Enable TensorRT acceleration for neural inference") orelse false;
    const enable_pipewire = b.option(bool, "pipewire", "Enable PipeWire audio backend") orelse true;
    const enable_jack = b.option(bool, "jack", "Enable JACK audio backend") orelse true;
    const enable_alsa = b.option(bool, "alsa", "Enable ALSA raw hw: mmap audio backend") orelse true;
    const enable_neural = b.option(bool, "enable_neural", "Enable ONNX Runtime neural engine bindings") orelse false;
    const enable_webkit = b.option(bool, "enable_webkit", "Enable WebKitGTK UserMessage IPC bindings") orelse true;
    const test_filter = b.option([]const u8, "test-filter", "Filter test names (substring match)");

    const options = b.addOptions();
    options.addOption(bool, "enable_cuda", enable_cuda);
    options.addOption(bool, "enable_tensorrt", enable_tensorrt);
    options.addOption(bool, "enable_pipewire", enable_pipewire);
    options.addOption(bool, "enable_jack", enable_jack);
    options.addOption(bool, "enable_alsa", enable_alsa);
    options.addOption(bool, "enable_neural", enable_neural);
    options.addOption(bool, "enable_webkit", enable_webkit);

    // ── Root Module ──────────────────────────────────────────────
    const root_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_mod.addOptions("build_options", options);

    // ── Optional System Libraries ──────────────────────────────────
    // JACK/PipeWire shared libraries need libc (pthreads, TLS init).
    // Without libc, Zig skips glibc startup → segfault in JACK init.
    if (enable_jack or enable_pipewire or enable_alsa or enable_neural or enable_cuda or enable_tensorrt or enable_webkit) {
        root_mod.link_libc = true;
    }
    if (enable_cuda) {
        root_mod.linkSystemLibrary("cuda", .{});
    }
    if (enable_tensorrt) {
        root_mod.linkSystemLibrary("nvinfer", .{});
    }
    if (enable_jack) {
        root_mod.linkSystemLibrary("jack", .{});
    }
    if (enable_pipewire) {
        root_mod.linkSystemLibrary("pipewire-0.3", .{});
    }
    if (enable_alsa) {
        root_mod.linkSystemLibrary("asound", .{});
    }
    if (enable_neural) {
        root_mod.linkSystemLibrary("onnxruntime", .{});
    }
    if (enable_webkit) {
        root_mod.linkSystemLibrary("webkit2gtk-4.1", .{});
        root_mod.linkSystemLibrary("glib-2.0", .{});
        root_mod.linkSystemLibrary("gobject-2.0", .{});
        root_mod.linkSystemLibrary("gio-2.0", .{});
    }

    // ── Target 1: Standalone executable ────────────────────────────
    const exe = b.addExecutable(.{
        .name = "worldsynth",
        .root_module = root_mod,
    });
    b.installArtifact(exe);

    // ── Target 2: CLAP plugin (shared library) ─────────────────────
    // Source files added in WP-032+ (Sprint 2)
    const plugin_step = b.step("plugin", "Build CLAP plugin (.clap)");
    _ = plugin_step;

    // ── Target 3: Benchmarks ───────────────────────────────────────
    // Benchmark harness added in later WPs
    const bench_step = b.step("bench", "Build and run benchmarks");
    _ = bench_step;

    // ── Target 4: synth-ctl CLI (WP-135) ────────────────────────────
    // Standalone binary — connects to Unix socket, no engine dependencies.
    const ctl_mod = b.createModule(.{
        .root_source_file = b.path("src/ctl_main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ctl_exe = b.addExecutable(.{
        .name = "synth-ctl",
        .root_module = ctl_mod,
    });
    b.installArtifact(ctl_exe);
    const ctl_step = b.step("ctl", "Build synth-ctl CLI tool");
    ctl_step.dependOn(&ctl_exe.step);

    // ── Tests ──────────────────────────────────────────────────────
    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addOptions("build_options", options);

    if (enable_jack or enable_pipewire or enable_alsa or enable_neural or enable_cuda or enable_tensorrt or enable_webkit) {
        test_mod.link_libc = true;
    }
    if (enable_cuda) {
        test_mod.linkSystemLibrary("cuda", .{});
    }
    if (enable_tensorrt) {
        test_mod.linkSystemLibrary("nvinfer", .{});
    }
    if (enable_jack) {
        test_mod.linkSystemLibrary("jack", .{});
    }
    if (enable_pipewire) {
        test_mod.linkSystemLibrary("pipewire-0.3", .{});
    }
    if (enable_alsa) {
        test_mod.linkSystemLibrary("asound", .{});
    }
    if (enable_neural) {
        test_mod.linkSystemLibrary("onnxruntime", .{});
    }
    if (enable_webkit) {
        test_mod.linkSystemLibrary("webkit2gtk-4.1", .{});
        test_mod.linkSystemLibrary("glib-2.0", .{});
        test_mod.linkSystemLibrary("gobject-2.0", .{});
        test_mod.linkSystemLibrary("gio-2.0", .{});
    }

    const unit_tests = b.addTest(.{
        .root_module = test_mod,
        .filters = if (test_filter) |f| &.{f} else &.{},
    });

    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const user_message_test_mod = b.createModule(.{
        .root_source_file = b.path("src/user_message_test_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    user_message_test_mod.addOptions("build_options", options);
    if (enable_webkit) {
        user_message_test_mod.link_libc = true;
        user_message_test_mod.linkSystemLibrary("webkit2gtk-4.1", .{});
        user_message_test_mod.linkSystemLibrary("glib-2.0", .{});
        user_message_test_mod.linkSystemLibrary("gobject-2.0", .{});
        user_message_test_mod.linkSystemLibrary("gio-2.0", .{});
    }

    const user_message_tests = b.addTest(.{
        .root_module = user_message_test_mod,
    });
    const run_user_message_tests = b.addRunArtifact(user_message_tests);
    const test_user_message_step = b.step("test-user-message", "Run WebKit UserMessage IPC tests");
    test_user_message_step.dependOn(&run_user_message_tests.step);

    const user_message_bench = b.addTest(.{
        .root_module = user_message_test_mod,
        .filters = &.{"benchmark: WP-029"},
    });
    const run_user_message_bench = b.addRunArtifact(user_message_bench);
    const bench_user_message_step = b.step("bench-user-message", "Run WP-029 UserMessage benchmarks");
    bench_user_message_step.dependOn(&run_user_message_bench.step);

    // Install test binary to zig-out/bin/ for local benchmark execution
    b.installArtifact(unit_tests);
}
