const std = @import("std");
const builtin = @import("builtin");
// NB: Don't import anything from `./src` to keep compile times low.

const assert = std.debug.assert;
const Query = std.Target.Query;

const VoprStateMachine = enum { nerva, testing };
const VoprLog = enum { short, full };
const TestCommitKeys = enum { on, off };

// Nerva has no client releases yet; every build is "the" release.
// 0.0.5: data files record the export they were imported from, and pings and pongs carry it
// (P90). Clients are unchanged, so 0.0.4's are still accepted.
// 0.0.6: a commit may start with a `key` entry, and writes its key's row (P123), so 0.0.5 and
// 0.0.6 replicas would diverge on it. Clients only gained an entry kind: 0.0.4's still work.
const release = "0.0.6";
const release_client_min = "0.0.4";
// Only `zig build test:release` builds this release, to run a cluster of two releases (N61).
const release_test_other = "0.0.200";
// The one past release a binary bundles, so that a cluster can move from it to `release` one
// replica at a time (R6, P259). None until the packer exists (R6 slice 3). A release that rolls
// keeps `release_client_min` at or below the bundled release, so that the past release's clients
// stay valid after the switch.
const release_bundled: ?[]const u8 = null;

comptime {
    @setEvalBranchQuota(10_000);
    const current = std.SemanticVersion.parse(release) catch unreachable;
    const client_min = std.SemanticVersion.parse(release_client_min) catch unreachable;
    assert(client_min.order(current) != .gt);
    if (release_bundled) |bundled_text| {
        const bundled = std.SemanticVersion.parse(bundled_text) catch unreachable;
        assert(bundled.order(current) == .lt);
        assert(client_min.order(bundled) != .gt);
    }
}

const zig_version = std.SemanticVersion{
    .major = 0,
    .minor = 14,
    .patch = 1,
};

comptime {
    const zig_version_equal =
        zig_version.major == builtin.zig_version.major and
        zig_version.minor == builtin.zig_version.minor and
        zig_version.patch == builtin.zig_version.patch;
    if (!zig_version_equal) {
        @compileError(std.fmt.comptimePrint(
            "unsupported zig version: expected {}, found {}",
            .{ zig_version, builtin.zig_version },
        ));
    }
}

// The vendored TigerBeetle code requires certain CPU features (AES for checksums).
fn resolve_target(b: *std.Build, target_requested: ?[]const u8) !std.Build.ResolvedTarget {
    const target_host = @tagName(builtin.target.cpu.arch) ++ "-" ++ @tagName(builtin.target.os.tag);
    const target = target_requested orelse target_host;
    const triples = .{
        "aarch64-linux",
        "aarch64-macos",
        "x86_64-linux",
        "x86_64-macos",
    };
    const cpus = .{
        "baseline+aes+neon",
        "baseline+aes+neon",
        "x86_64_v3+aes",
        "x86_64_v3+aes",
    };

    const arch_os, const cpu = inline for (triples, cpus) |triple, cpu| {
        if (std.mem.eql(u8, target, triple)) break .{ triple, cpu };
    } else {
        std.log.err("unsupported target: '{s}'", .{target});
        return error.UnsupportedTarget;
    };
    const query = try Query.parse(.{
        .arch_os_abi = arch_os,
        .cpu_features = cpu,
    });
    return b.resolveTargetQuery(query);
}

pub fn build(b: *std.Build) !void {
    // A compile error stack trace of 10 is arbitrary in size but helps with debugging.
    b.reference_trace = 10;

    const mode = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const target = try resolve_target(b, b.option(
        []const u8,
        "target",
        "The CPU architecture and OS to build for",
    ));

    const steps = .{
        .run = b.step("run", "Run nerva"),
        .check = b.step("check", "Check that Nerva compiles"),
        .@"test" = b.step("test", "Run all tests"),
        .test_unit = b.step("test:unit", "Run unit tests"),
        .test_unit_build = b.step("test:unit:build", "Build unit tests"),
        .test_fmt = b.step("test:fmt", "Check formatting"),
        .test_integration = b.step("test:integration", "Run integration tests (real processes)"),
        .test_api = b.step("test:api", "Check nerva api against models (python3)"),
        .test_views = b.step("test:views", "Check declared views against a model (python3)"),
        .test_release = b.step(
            "test:release",
            "Run a cluster of two releases, and an upgrade by export and import (python3)",
        ),
        .test_demo = b.step("test:demo", "Run the demos under crashes (python3)"),
        .demo_r4 = b.step("demo-r4", "Run R4's demo: gateway (python3)"),
        .demo_r5 = b.step("demo-r5", "Run R5's demo: recover, backup, restore (python3)"),
        .vopr = b.step("vopr", "Run the VOPR"),
        .vopr_build = b.step("vopr:build", "Build the VOPR"),
        .fuzz = b.step("fuzz", "Run non-VOPR fuzzers"),
        .fuzz_build = b.step("fuzz:build", "Build non-VOPR fuzzers"),
        .bench = b.step("bench", "Run every `benchmark:` test for real (ReleaseSafe)"),
        .bench_build = b.step(
            "bench:build",
            "Install the benchmark binaries and bench-load to zig-out/bin, without running them",
        ),
        .bench_load = b.step("bench:load", "Run the load generator (ReleaseSafe; pass flags after --)"),
    };

    const mac_release = @import("src/nerva/mac_release.zig");
    const options = .{
        .config_verify = b.option(bool, "config_verify", "Enable extra assertions.") orelse
            (mode == .Debug),
        .git_commit = b.option(
            []const u8,
            "git-commit",
            "The git commit of the source code.",
        ) orelse
            git_commit(b),
        .vopr_state_machine = b.option(
            VoprStateMachine,
            "vopr-state-machine",
            "State machine.",
        ) orelse .nerva,
        .vopr_log = b.option(
            VoprLog,
            "vopr-log",
            "Log only state transitions (short) or everything (full).",
        ) orelse .short,
        .test_commit_keys = b.option(
            TestCommitKeys,
            "test-commit-keys",
            "off: a test `nerva` that commits a resent key again; it starts only with " ++
                "--development (R1)",
        ) orelse .on,
        .version = b.option(
            []const u8,
            "version",
            "The release `nerva version` names (default: VERSION's contents).",
        ) orelse version_file(b),
        .print_exe = b.option(
            bool,
            "print-exe",
            "Build tasks print the path of the executable",
        ) orelse false,
    };

    if (!mac_release.version_valid(options.version)) {
        std.log.err(
            "-Dversion (or VERSION) '{s}' is not a release version: want N.N.N or N.N.N-suffix " ++
                "(letters, digits, dots), at most {} characters",
            .{ options.version, mac_release.version_length_max },
        );
        return error.InvalidVersion;
    }

    const test_options = b.addOptions();
    // Benchmarks run in two modes:
    // - ./zig/zig build test                             (small parameters, silent)
    // - ./zig/zig build -Drelease test -- "benchmark: name" (real benchmark, prints output)
    test_options.addOption(bool, "benchmark", for (b.args orelse &.{}) |arg| {
        if (std.mem.indexOf(u8, arg, "benchmark") != null) break true;
    } else false);

    const stdx_module = b.addModule("stdx", .{ .root_source_file = b.path("src/stdx/stdx.zig") });
    stdx_module.addOptions("test_options", test_options);

    const vsr_options = b.addOptions();
    assert(options.git_commit.len == 40);
    vsr_options.addOption(?[40]u8, "git_commit", options.git_commit[0..40].*);
    vsr_options.addOption(bool, "config_verify", options.config_verify);
    vsr_options.addOption([]const u8, "release", release);
    vsr_options.addOption([]const u8, "release_client_min", release_client_min);

    // Tests and simulators always run with extra assertions.
    const vsr_options_test = b.addOptions();
    vsr_options_test.addOption(?[40]u8, "git_commit", options.git_commit[0..40].*);
    vsr_options_test.addOption(bool, "config_verify", true);
    vsr_options_test.addOption([]const u8, "release", release);
    vsr_options_test.addOption([]const u8, "release_client_min", release_client_min);

    // zig build check
    const check_module = vsr_module(b, .{
        .stdx_module = stdx_module,
        .vsr_options = vsr_options,
        .test_options = test_options,
        .target = target,
        .mode = mode,
    });
    const check = b.addTest(.{
        .name = "check",
        .root_module = check_module,
        .filters = &.{"nonexistent test name; compile only"},
    });
    steps.check.dependOn(&check.step);

    // zig build, zig build run
    const nerva = nerva_executable(b, .{
        .stdx_module = stdx_module,
        .vsr_options = vsr_options,
        .target = target,
        .mode = mode,
        .version = options.version,
        .commit_keys_deduplicate = options.test_commit_keys == .on,
    });
    b.installArtifact(nerva);
    // The same build with deduplication off, for `tests/errors/commands.py` (R1). Never
    // installed; when `-Dtest-commit-keys=off`, `nerva` itself is that build.
    const nerva_keys_off = nerva_executable(b, .{
        .stdx_module = stdx_module,
        .vsr_options = vsr_options,
        .target = target,
        .mode = mode,
        .version = options.version,
        .commit_keys_deduplicate = false,
    });
    const nerva_run = b.addRunArtifact(nerva);
    if (b.args) |args| nerva_run.addArgs(args);
    steps.run.dependOn(&nerva_run.step);
    steps.check.dependOn(&nerva.step);
    steps.check.dependOn(&nerva_keys_off.step);
    add_mac_release(
        b,
        steps.check,
        stdx_module,
        vsr_options,
        options.version,
        mode == .ReleaseSafe and !options.config_verify,
    );

    // zig build test:unit
    const stdx_unit_tests = b.addTest(.{
        .name = "test-stdx",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/stdx/stdx.zig"),
            .target = target,
            .optimize = mode,
        }),
        .filters = b.args orelse &.{},
    });
    stdx_unit_tests.root_module.addOptions("test_options", test_options);

    const unit_tests = b.addTest(.{
        .name = "test-unit",
        .root_module = vsr_module(b, .{
            .stdx_module = stdx_module,
            .vsr_options = vsr_options_test,
            .test_options = test_options,
            .target = target,
            .mode = mode,
        }),
        .filters = b.args orelse &.{},
    });

    steps.test_unit_build.dependOn(&b.addInstallArtifact(stdx_unit_tests, .{}).step);
    steps.test_unit_build.dependOn(&b.addInstallArtifact(unit_tests, .{}).step);

    const run_stdx_unit_tests = b.addRunArtifact(stdx_unit_tests);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    run_stdx_unit_tests.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
    run_unit_tests.setEnvironmentVariable("ZIG_EXE", b.graph.zig_exe);
    run_unit_tests.setCwd(b.path("."));
    if (b.args != null) { // Don't cache test results if running a specific test.
        run_stdx_unit_tests.has_side_effects = true;
        run_unit_tests.has_side_effects = true;
    }
    steps.test_unit.dependOn(&run_stdx_unit_tests.step);
    steps.test_unit.dependOn(&run_unit_tests.step);

    // zig build bench [-- <filter>]
    // Every `benchmark:` test in benchmark mode, ReleaseSafe whatever -Drelease says. Machine
    // results are `bench-json:` lines on stderr (`Bench.metric`).
    const test_options_bench = b.addOptions();
    test_options_bench.addOption(bool, "benchmark", true);
    const stdx_module_bench = b.createModule(.{
        .root_source_file = b.path("src/stdx/stdx.zig"),
    });
    stdx_module_bench.addOptions("test_options", test_options_bench);
    const bench_filters: []const []const u8 = b.args orelse &.{"benchmark:"};
    const stdx_benchmarks = b.addTest(.{
        .name = "bench-stdx",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/stdx/stdx.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
        .filters = bench_filters,
    });
    stdx_benchmarks.root_module.addOptions("test_options", test_options_bench);
    const benchmarks = b.addTest(.{
        .name = "bench",
        .root_module = vsr_module(b, .{
            .stdx_module = stdx_module_bench,
            .vsr_options = vsr_options_test,
            .test_options = test_options_bench,
            .target = target,
            .mode = .ReleaseSafe,
        }),
        .filters = bench_filters,
    });
    for ([_]*std.Build.Step.Compile{ stdx_benchmarks, benchmarks }) |compile| {
        steps.bench_build.dependOn(&b.addInstallArtifact(compile, .{}).step);
        const run = b.addRunArtifact(compile);
        run.setCwd(b.path("."));
        run.has_side_effects = true; // Never cached: a benchmark is run to be measured.
        steps.bench.dependOn(&run.step);
    }

    // zig build bench:load -- <flags>
    // An executable, not a test: it must use the same (production) config as `nerva`.
    const bench_load_options = b.addOptions();
    bench_load_options.addOptionPath("nerva_exe", nerva.getEmittedBin());
    const bench_load = b.addExecutable(.{
        .name = "bench-load",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_load.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
        }),
    });
    bench_load.root_module.addImport("stdx", stdx_module);
    bench_load.root_module.addImport(
        "abi",
        b.createModule(.{ .root_source_file = b.path("src/abi.zig") }),
    );
    bench_load.root_module.addOptions("vsr_options", vsr_options_test);
    bench_load.root_module.addOptions("bench_load_options", bench_load_options);
    steps.check.dependOn(&bench_load.step);
    steps.bench_build.dependOn(&b.addInstallArtifact(bench_load, .{}).step);
    const run_bench_load = b.addRunArtifact(bench_load);
    if (b.args) |args| run_bench_load.addArgs(args);
    run_bench_load.has_side_effects = true;
    steps.bench_load.dependOn(&run_bench_load.step);

    // zig build test:integration
    const integration_tests_options = b.addOptions();
    integration_tests_options.addOptionPath("nerva_exe", nerva.getEmittedBin());
    // An executable, not a test: it must use the same (production) config as `nerva`.
    const integration_tests = b.addExecutable(.{
        .name = "test-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/integration_tests.zig"),
            .target = target,
            .optimize = mode,
        }),
    });
    integration_tests.root_module.addImport("stdx", stdx_module);
    integration_tests.root_module.addImport(
        "abi",
        b.createModule(.{ .root_source_file = b.path("src/abi.zig") }),
    );
    integration_tests.root_module.addOptions("vsr_options", vsr_options_test);
    integration_tests.root_module.addOptions(
        "integration_tests_options",
        integration_tests_options,
    );
    const run_integration_tests = b.addRunArtifact(integration_tests);
    run_integration_tests.setCwd(b.path("."));
    run_integration_tests.has_side_effects = true; // Never cache: it runs real processes.
    steps.test_integration.dependOn(&run_integration_tests.step);

    // The coded failures of every command, from the real binary (R5, P147c).
    const run_errors_test = b.addSystemCommand(&.{ "python3", "tests/errors/commands.py" });
    run_errors_test.addFileArg(nerva.getEmittedBin());
    run_errors_test.addFileArg(nerva_keys_off.getEmittedBin());
    run_errors_test.setCwd(b.path("."));
    run_errors_test.has_side_effects = true;
    run_errors_test.step.dependOn(&run_integration_tests.step);
    steps.test_integration.dependOn(&run_errors_test.step);

    // `nerva recover` on three real replicas (R5): after the integration tests, which run a
    // cluster of their own.
    const run_recover_test = b.addSystemCommand(&.{ "python3", "tests/recover/recover.py" });
    run_recover_test.addFileArg(nerva.getEmittedBin());
    run_recover_test.setCwd(b.path("."));
    run_recover_test.has_side_effects = true;
    run_recover_test.step.dependOn(&run_integration_tests.step);
    steps.test_integration.dependOn(&run_recover_test.step);

    // zig build test:api: the JSON API, its documents, adds, commit keys (P123), records and
    // indexes (P123b, P123c), then layouts kept between requests (P135), then ledgers, against
    // models, then a cluster and gateway over IPv6 (skipped without it), a gateway given an
    // address it cannot open (#92), then key rotation through both gateways (NERVA_KEY_NEXT), a
    // gateway with more connections than slots (R4), its statsd metrics, and every code it puts
    // on the wire; one after the other: each runs a cluster.
    var api_previous: ?*std.Build.Step = null;
    for ([_][]const u8{
        "api.py",
        "documents.py",
        "adds.py",
        "commit_keys.py",
        "records.py",
        "layouts.py",
        "ledgers.py",
        "ipv6.py",
        "addresses.py",
        "keys.py",
        "busy.py",
        "metrics.py",
        "docs_routes.py",
        "../errors/wire.py",
    }) |script| {
        const run_api_test = b.addSystemCommand(&.{ "python3", b.fmt("tests/api/{s}", .{script}) });
        run_api_test.addFileArg(nerva.getEmittedBin());
        if (b.args) |args| run_api_test.addArgs(args);
        run_api_test.setCwd(b.path("."));
        run_api_test.has_side_effects = true;
        if (api_previous) |previous| run_api_test.step.dependOn(previous);
        api_previous = &run_api_test.step;
        steps.test_api.dependOn(&run_api_test.step);
    }

    // zig build test:views: declared views against a model, then views maintained by the state
    // machine against `nerva view` (one after the other: each runs a cluster).
    var views_previous: ?*std.Build.Step = null;
    for ([_][]const u8{ "declared.py", "maintained.py" }) |script| {
        const run_views_test = b.addSystemCommand(&.{
            "python3",
            b.fmt("tests/views/{s}", .{script}),
        });
        run_views_test.addFileArg(nerva.getEmittedBin());
        if (b.args) |args| run_views_test.addArgs(args);
        run_views_test.setCwd(b.path("."));
        run_views_test.has_side_effects = true;
        if (views_previous) |previous| run_views_test.step.dependOn(previous);
        views_previous = &run_views_test.step;
        steps.test_views.dependOn(&run_views_test.step);
    }

    // zig build test:release: a cluster of two releases (N61). The second `nerva` differs only in
    // its release string, which no real release uses; it is built for this test, never installed.
    const vsr_options_other = b.addOptions();
    vsr_options_other.addOption(?[40]u8, "git_commit", options.git_commit[0..40].*);
    vsr_options_other.addOption(bool, "config_verify", options.config_verify);
    vsr_options_other.addOption([]const u8, "release", release_test_other);
    vsr_options_other.addOption([]const u8, "release_client_min", release_client_min);
    const nerva_other = nerva_executable(b, .{
        .stdx_module = stdx_module,
        .vsr_options = vsr_options_other,
        .target = target,
        .mode = mode,
        .version = options.version,
    });
    // `origins.py` also runs a client of the oldest release this build accepts: the same code
    // under `release_client_min` (P90).
    const vsr_options_client = b.addOptions();
    vsr_options_client.addOption(?[40]u8, "git_commit", options.git_commit[0..40].*);
    vsr_options_client.addOption(bool, "config_verify", options.config_verify);
    vsr_options_client.addOption([]const u8, "release", release_client_min);
    vsr_options_client.addOption([]const u8, "release_client_min", release_client_min);
    const nerva_client_min = nerva_executable(b, .{
        .stdx_module = stdx_module,
        .vsr_options = vsr_options_client,
        .target = target,
        .mode = mode,
        .version = options.version,
    });
    // Then an upgrade: an export from `nerva`, imported by the other release (N80), without
    // records (export version 1) and with them (version 2, P123b); then replicas imported from
    // different exports (P90); then a backup, a restore drill and a restore (R5). One after the other: each runs a cluster.
    var release_previous: ?*std.Build.Step = null;
    for ([_][2][]const u8{
        .{ "mixed.py", "" },
        .{ "upgrade.py", "" },
        .{ "upgrade.py", "--records" },
        .{ "origins.py", "" },
        .{ "recover.py", "" },
        .{ "restore.py", "" },
    }) |release_test| {
        const script = release_test[0];
        const run_release_test = b.addSystemCommand(&.{
            "python3",
            b.fmt("tests/release/{s}", .{script}),
        });
        run_release_test.addFileArg(nerva.getEmittedBin());
        const nerva_second = if (std.mem.eql(u8, script, "origins.py"))
            nerva_client_min
        else
            nerva_other;
        run_release_test.addFileArg(nerva_second.getEmittedBin());
        if (release_test[1].len > 0) run_release_test.addArg(release_test[1]);
        if (b.args) |args| run_release_test.addArgs(args);
        run_release_test.setCwd(b.path("."));
        run_release_test.has_side_effects = true;
        if (release_previous) |previous| run_release_test.step.dependOn(previous);
        release_previous = &run_release_test.step;
        steps.test_release.dependOn(&run_release_test.step);
    }

    // zig build test:demo: the demos under crashes, one after the other (each runs a cluster).
    var demo_previous: ?*std.Build.Step = null;
    for ([_][]const u8{ "seats_chaos.py", "canvas_chaos.py" }) |script| {
        const run_demo_test = b.addSystemCommand(&.{
            "python3",
            b.fmt("tests/demo/{s}", .{script}),
        });
        run_demo_test.addFileArg(nerva.getEmittedBin());
        if (b.args) |args| run_demo_test.addArgs(args);
        run_demo_test.setCwd(b.path("."));
        run_demo_test.has_side_effects = true;
        if (demo_previous) |previous| run_demo_test.step.dependOn(previous);
        demo_previous = &run_demo_test.step;
        steps.test_demo.dependOn(&run_demo_test.step);
    }

    // zig build demo-r4: R4's demo (docs/briefs/r4.md, docs/demos/r4.md), two clients, each with a
    // gateway, on three replicas. Not part of any other step: CI runs it as `demo_r4`.
    const run_demo_r4 = b.addSystemCommand(&.{ "python3", "tests/demo/r4.py" });
    run_demo_r4.addFileArg(nerva.getEmittedBin());
    if (b.args) |args| run_demo_r4.addArgs(args);
    run_demo_r4.setCwd(b.path("."));
    run_demo_r4.has_side_effects = true;
    steps.demo_r4.dependOn(&run_demo_r4.step);

    // zig build demo-r5: R5's demo (docs/briefs/r5.md, docs/demos/r5.md), three replicas, a
    // recovered one, a backup and restores. Not part of any other step: CI runs it as `demo_r5`.
    const run_demo_r5 = b.addSystemCommand(&.{ "python3", "tests/demo/r5.py" });
    run_demo_r5.addFileArg(nerva.getEmittedBin());
    if (b.args) |args| run_demo_r5.addArgs(args);
    run_demo_r5.setCwd(b.path("."));
    run_demo_r5.has_side_effects = true;
    steps.demo_r5.dependOn(&run_demo_r5.step);

    // zig build test:fmt
    const run_fmt = b.addFmt(.{ .paths = &.{ "build.zig", "src" }, .check = true });
    steps.test_fmt.dependOn(&run_fmt.step);

    steps.@"test".dependOn(steps.test_unit);
    if (b.args == null) steps.@"test".dependOn(steps.test_fmt);

    // zig build vopr
    const vopr_options = b.addOptions();
    vopr_options.addOption(VoprStateMachine, "state_machine", options.vopr_state_machine);
    vopr_options.addOption(VoprLog, "log", options.vopr_log);

    const vopr = b.addExecutable(.{
        .name = "vopr",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vopr.zig"),
            .target = target,
            // When running without a SEED, default to release.
            .optimize = if (b.args == null) .ReleaseSafe else mode,
        }),
    });
    vopr.stack_size = 4 * MiB;
    vopr.root_module.addImport("stdx", stdx_module);
    vopr.root_module.addOptions("vsr_options", vsr_options_test);
    vopr.root_module.addOptions("vsr_vopr_options", vopr_options);
    // Ensure that we get stack traces even in release builds.
    vopr.root_module.omit_frame_pointer = false;
    steps.vopr_build.dependOn(print_or_install(b, vopr, options.print_exe));

    const vopr_run = b.addRunArtifact(vopr);
    if (b.args) |args| vopr_run.addArgs(args);
    steps.vopr.dependOn(&vopr_run.step);

    // zig build fuzz
    const fuzz = b.addExecutable(.{
        .name = "fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz_tests.zig"),
            .target = target,
            .optimize = mode,
        }),
    });
    fuzz.stack_size = 4 * MiB;
    fuzz.root_module.addImport("stdx", stdx_module);
    fuzz.root_module.addOptions("vsr_options", vsr_options_test);
    fuzz.root_module.omit_frame_pointer = false;
    steps.fuzz_build.dependOn(print_or_install(b, fuzz, options.print_exe));

    const fuzz_run = b.addRunArtifact(fuzz);
    if (b.args) |args| fuzz_run.addArgs(args);
    steps.fuzz.dependOn(&fuzz_run.step);
}

fn nerva_executable(b: *std.Build, options: struct {
    stdx_module: *std.Build.Module,
    vsr_options: *std.Build.Step.Options,
    target: std.Build.ResolvedTarget,
    mode: std.builtin.OptimizeMode,
    version: []const u8,
    commit_keys_deduplicate: bool = true,
}) *std.Build.Step.Compile {
    const nerva = b.addExecutable(.{
        .name = "nerva",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/nerva_main.zig"),
            .target = options.target,
            .optimize = options.mode,
        }),
    });
    nerva.root_module.addImport("stdx", options.stdx_module);
    nerva.root_module.addImport(
        "abi",
        b.createModule(.{ .root_source_file = b.path("src/abi.zig") }),
    );
    nerva.root_module.addOptions("vsr_options", options.vsr_options);
    // Only this binary's `start` can turn commit-key deduplication off (R1).
    const nerva_options = b.addOptions();
    nerva_options.addOption(bool, "commit_keys_deduplicate", options.commit_keys_deduplicate);
    nerva_options.addOption([]const u8, "version", options.version);
    nerva.root_module.addOptions("nerva_options", nerva_options);
    // Keep stack traces in release builds.
    nerva.root_module.omit_frame_pointer = false;
    return nerva;
}

fn vsr_module(b: *std.Build, options: struct {
    stdx_module: *std.Build.Module,
    vsr_options: *std.Build.Step.Options,
    test_options: *std.Build.Step.Options,
    target: std.Build.ResolvedTarget,
    mode: std.builtin.OptimizeMode,
}) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/vsr.zig"),
        .target = options.target,
        .optimize = options.mode,
    });
    module.addImport("stdx", options.stdx_module);
    module.addImport("abi", b.createModule(.{ .root_source_file = b.path("src/abi.zig") }));
    module.addOptions("vsr_options", options.vsr_options);
    module.addOptions("test_options", options.test_options);
    return module;
}

/// `VERSION`'s contents: what `nerva version` names as the release (v0.7.1, P284).
fn version_file(b: *std.Build) []const u8 {
    const text = b.build_root.handle.readFileAlloc(b.allocator, "VERSION", 64) catch
        @panic("cannot read VERSION; pass -Dversion");
    return std.mem.trim(u8, text, " \r\n");
}

/// `zig build mac-release` (v0.7.1, P284): the universal macOS binary, signed, zipped and
/// optionally notarized, and the Homebrew formula; see src/nerva/mac_release.zig. Run on a Mac,
/// by the owner; `-Dsign-identity=-` signs ad hoc, as CI does. Nothing is compiled or signed
/// before its `preflight` run has checked the tree, the tag, the identity and the notary profile.
fn add_mac_release(
    b: *std.Build,
    check: *std.Build.Step,
    stdx_module: *std.Build.Module,
    vsr_options: *std.Build.Step.Options,
    version: []const u8,
    release_build: bool,
) void {
    const mac_release = @import("src/nerva/mac_release.zig");
    const identity = b.option(
        []const u8,
        "sign-identity",
        "mac-release: the codesign identity (- is ad hoc); default " ++ mac_release.default_identity,
    ) orelse mac_release.default_identity;
    const profile = b.option(
        []const u8,
        "notary-profile",
        "mac-release: the notarytool keychain profile; default " ++ mac_release.default_profile,
    ) orelse mac_release.default_profile;
    const notarize = b.option(
        bool,
        "notarize",
        "mac-release: submit the zip to Apple's notary service and wait",
    ) orelse false;

    const tool = b.addExecutable(.{
        .name = "mac_release",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/nerva/mac_release.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    check.dependOn(&tool.step);

    const preflight = b.addRunArtifact(tool);
    preflight.setCwd(b.path("."));
    preflight.addArgs(&.{ "preflight", "--version", version });
    preflight.addArgs(&.{ "--identity", identity, "--profile", profile });
    if (notarize) preflight.addArg("--notarize");
    preflight.has_side_effects = true;

    const package = b.addRunArtifact(tool);
    package.setCwd(b.path("."));
    package.addArgs(&.{ "package", "--version", version });
    package.addArgs(&.{ "--identity", identity, "--profile", profile });
    if (notarize) package.addArg("--notarize");
    package.has_side_effects = true;
    inline for (.{ "aarch64-macos", "x86_64-macos" }) |triple| {
        const thin = nerva_executable(b, .{
            .stdx_module = stdx_module,
            .vsr_options = vsr_options,
            .target = resolve_target(b, triple) catch unreachable,
            .mode = .ReleaseSafe,
            .version = version,
        });
        thin.step.dependOn(&preflight.step);
        package.addArg(if (comptime std.mem.startsWith(u8, triple, "aarch64"))
            "--arm64"
        else
            "--x86_64");
        package.addArtifactArg(thin);
    }
    // The thin binaries must be what `release.yml` builds with `-Drelease`: ReleaseSafe with
    // `config_verify` off. Anything else would ship the simulator's extra checks.
    if (!release_build) {
        const refuse = b.addFail("mac-release: run it as `zig build -Drelease mac-release` " ++
            "(the release's ReleaseSafe build, without the extra verification)");
        preflight.step.dependOn(&refuse.step);
        package.step.dependOn(&refuse.step);
    }
    const step = b.step("mac-release", "Sign, zip and optionally notarize the universal macOS nerva (use -Drelease)");
    step.dependOn(&package.step);
}

/// The current commit, or all zeros before the first commit / outside a git checkout.
fn git_commit(b: *std.Build) []const u8 {
    var exit_code: u8 = undefined;
    const output = b.runAllowFail(
        &.{ "git", "-C", b.path(".").getPath(b), "rev-parse", "--verify", "HEAD" },
        &exit_code,
        .Ignore,
    ) catch return "0" ** 40;
    return std.mem.trimRight(u8, output, "\n");
}

fn print_or_install(b: *std.Build, compile: *std.Build.Step.Compile, print: bool) *std.Build.Step {
    const PrintStep = struct {
        step: std.Build.Step,
        compile: *std.Build.Step.Compile,

        fn make(step: *std.Build.Step, _: std.Build.Step.MakeOptions) !void {
            const print_step: *@This() = @fieldParentPtr("step", step);
            const path = print_step.compile.getEmittedBin().getPath2(step.owner, step);
            try std.io.getStdOut().writer().print("{s}\n", .{path});
        }
    };

    if (print) {
        const print_step = b.allocator.create(PrintStep) catch @panic("OOM");
        print_step.* = .{
            .step = std.Build.Step.init(.{
                .id = .custom,
                .name = "print exe",
                .owner = b,
                .makeFn = PrintStep.make,
            }),
            .compile = compile,
        };
        print_step.step.dependOn(&print_step.compile.step);
        return &print_step.step;
    } else {
        return &b.addInstallArtifact(compile, .{}).step;
    }
}

const MiB = 1 << 20;
