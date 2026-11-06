const std = @import("std");
/// Zig version. When writing code that supports multiple versions of Zig, prefer
/// feature detection (i.e. with `@hasDecl` or `@hasField`) over version checks.
pub const zig_version = std.SemanticVersion.parse(zig_version_string) catch unreachable;
pub const zig_version_string = "0.14.1";
pub const zig_backend = std.builtin.CompilerBackend.stage2_llvm;

pub const output_mode: std.builtin.OutputMode = .Exe;
pub const link_mode: std.builtin.LinkMode = .static;
pub const unwind_tables: std.builtin.UnwindTables = .@"async";
pub const is_test = false;
pub const single_threaded = false;
pub const abi: std.Target.Abi = .gnu;
pub const cpu: std.Target.Cpu = .{
    .arch = .x86_64,
    .model = &std.Target.x86.cpu.emeraldrapids,
    .features = std.Target.x86.featureSet(&.{
        .@"64bit",
        .adx,
        .aes,
        .allow_light_256_bit,
        .amx_bf16,
        .amx_int8,
        .amx_tile,
        .avx,
        .avx2,
        .avx512bf16,
        .avx512bitalg,
        .avx512bw,
        .avx512cd,
        .avx512dq,
        .avx512f,
        .avx512fp16,
        .avx512ifma,
        .avx512vbmi,
        .avx512vbmi2,
        .avx512vl,
        .avx512vnni,
        .avx512vpopcntdq,
        .avxvnni,
        .bmi,
        .bmi2,
        .cldemote,
        .clflushopt,
        .clwb,
        .cmov,
        .crc32,
        .cx16,
        .cx8,
        .ermsb,
        .evex512,
        .f16c,
        .false_deps_getmant,
        .false_deps_mulc,
        .false_deps_mullq,
        .false_deps_perm,
        .false_deps_range,
        .fast_15bytenop,
        .fast_gather,
        .fast_scalar_fsqrt,
        .fast_shld_rotate,
        .fast_variable_crosslane_shuffle,
        .fast_variable_perlane_shuffle,
        .fast_vector_fsqrt,
        .fma,
        .fsgsbase,
        .fsrm,
        .fxsr,
        .gfni,
        .idivq_to_divl,
        .invpcid,
        .lzcnt,
        .macrofusion,
        .mmx,
        .movbe,
        .movdir64b,
        .movdiri,
        .no_bypass_delay_blend,
        .no_bypass_delay_mov,
        .no_bypass_delay_shuffle,
        .nopl,
        .pclmul,
        .popcnt,
        .prefer_256_bit,
        .prfchw,
        .rdpid,
        .rdrnd,
        .rdseed,
        .rtm,
        .sahf,
        .serialize,
        .sha,
        .smap,
        .smep,
        .sse,
        .sse2,
        .sse3,
        .sse4_1,
        .sse4_2,
        .ssse3,
        .tsxldtrk,
        .tuning_fast_imm_vector_shift,
        .vaes,
        .vpclmulqdq,
        .vzeroupper,
        .wbnoinvd,
        .x87,
        .xsave,
        .xsavec,
        .xsaveopt,
        .xsaves,
    }),
};
pub const os: std.Target.Os = .{
    .tag = .linux,
    .version_range = .{ .linux = .{
        .range = .{
            .min = .{
                .major = 6,
                .minor = 18,
                .patch = 44,
            },
            .max = .{
                .major = 6,
                .minor = 18,
                .patch = 44,
            },
        },
        .glibc = .{
            .major = 2,
            .minor = 39,
            .patch = 0,
        },
        .android = 14,
    }},
};
pub const target: std.Target = .{
    .cpu = cpu,
    .os = os,
    .abi = abi,
    .ofmt = object_format,
    .dynamic_linker = .init("/lib64/ld-linux-x86-64.so.2"),
};
pub const object_format: std.Target.ObjectFormat = .elf;
pub const mode: std.builtin.OptimizeMode = .Debug;
pub const link_libc = false;
pub const link_libcpp = false;
pub const have_error_return_tracing = true;
pub const valgrind_support = true;
pub const sanitize_thread = false;
pub const fuzz = false;
pub const position_independent_code = false;
pub const position_independent_executable = false;
pub const strip_debug_info = false;
pub const code_model: std.builtin.CodeModel = .default;
pub const omit_frame_pointer = false;
