const std = @import("std");
const builtin = @import("builtin");
// NB: Don't import anything from `./src` to keep compile times low.

const assert = std.debug.assert;
const Query = std.Target.Query;

const VoprStateMachine = enum { nerva, testing };
const VoprLog = enum { short, full };

// Nerva has no client releases yet; every build is "the" release.
const release = "0.0.1";
const release_client_min = "0.0.1";

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
        .test_ledgerd = b.step("test:ledgerd", "Check nerva ledgerd against ledgerd.py (python3)"),
        .vopr = b.step("vopr", "Run the VOPR"),
        .vopr_build = b.step("vopr:build", "Build the VOPR"),
        .fuzz = b.step("fuzz", "Run non-VOPR fuzzers"),
        .fuzz_build = b.step("fuzz:build", "Build non-VOPR fuzzers"),
    };

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
        .print_exe = b.option(
            bool,
            "print-exe",
            "Build tasks print the path of the executable",
        ) orelse false,
    };

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
    });
    b.installArtifact(nerva);
    const nerva_run = b.addRunArtifact(nerva);
    if (b.args) |args| nerva_run.addArgs(args);
    steps.run.dependOn(&nerva_run.step);
    steps.check.dependOn(&nerva.step);

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

    // zig build test:ledgerd: differential and race tests against the runtime's ledgerd.py.
    for ([_][]const u8{ "conformance.py", "race.py" }) |script| {
        const run_script = b.addSystemCommand(&.{
            "python3",
            b.fmt("tests/ledgerd/{s}", .{script}),
        });
        run_script.addFileArg(nerva.getEmittedBin());
        if (b.args) |args| run_script.addArgs(args);
        run_script.setCwd(b.path("."));
        run_script.has_side_effects = true;
        steps.test_ledgerd.dependOn(&run_script.step);
    }

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
