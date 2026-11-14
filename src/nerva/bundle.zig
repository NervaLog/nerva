//! Packing a past release into a `nerva` binary (R6 slice 3, P259d, P417).
//!
//! `zig build -Dbundle=<N's nerva>` makes a `nerva` that carries release N beside its own code, so
//! that a cluster can move from N to this release one replica at a time (P259). Upstream's packer
//! (`build_multiversion.zig`) calls `llvm-objcopy`, a dependency Nerva does not take (P259d), so
//! this file writes the same layout itself, for ELF (Linux, x86_64 and aarch64):
//!
//! ```
//! the linked executable, byte for byte      <- what `zig build` made
//! .tb_mvb   the past release's whole executable, unchanged
//! .tb_mvh   `MultiversionHeader` (upstream's, used as is)
//! the section names, and the section headers, with the two sections above last
//! "nervapaknervapak"                        <- a trailer: this is a packed binary
//! ```
//!
//! Both sections are not loaded (no `SHF_ALLOC`), so the kernel runs the outer binary exactly as
//! linked. `MultiversionOS` finds them by name, checks the header's checksum and the checksum of
//! the whole file with the header zeroed (`multiversion.zig`, `target_update`), and copies a past
//! release out of the body into a `memfd` to execute it. The checks below repeat those, so that a
//! packed binary is proven to open before it is installed.
//!
//! A damaged binary is never read as "no bundle": a trailer that is nearly there, or either section
//! name, with the sections not found, is damage (NRV-E0719), so one changed byte anywhere is caught.
//!
//! The past release is an unpacked build (one release, no sections). A packed binary given as the
//! past release is stripped first (`strip`): the layout above only appends, and the one field the
//! append changes in place (the ELF header's `e_shoff` and `e_shnum`) is kept in the header's
//! `reserved` bytes, so that stripping gives back the linked executable exactly (its checksum is
//! `current_checksum`), and a binary never carries more than one past release (N43, P259).
//!
//! The packer refuses a past release that this release cannot take over from (`refusal`) and a
//! result over `multiversion_binary_platform_size_max` (NRV-E0719, `PackError.SizeMax`).
//! Nothing here is persisted by a replica or sent on the wire: a data file and a message are
//! unchanged.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const elf = std.elf;
const mem = std.mem;

const stdx = @import("stdx");
const constants = @import("../constants.zig");
const multiversion = @import("../multiversion.zig");

const Header = multiversion.MultiversionHeader;
const Release = multiversion.Release;

/// The name of the two sections, as `multiversion.zig` looks them up.
const section_body_name = ".tb_mvb";
const section_header_name = ".tb_mvh";
/// The last bytes of a packed binary, after the section header table. It is how a binary that
/// `pack` wrote is told from one it did not even when a changed byte hides the section table or
/// the names (NRV-E0719, not "no bundle"): see `bundle_traces`.
const trailer = "nervapaknervapak";

/// What the packer writes into `Header.reserved`, so that `strip` can undo the append. Upstream
/// leaves `reserved` unchecked for new fields.
const Origin = extern struct {
    magic: [8]u8,
    /// `e_shoff` of the linked executable.
    section_headers_offset: u64,

    const magic_value: [8]u8 = "nervapak".*;

    comptime {
        assert(@sizeOf(Origin) == 16);
        assert(@sizeOf(Origin) <= @sizeOf(@FieldType(Header, "reserved")));
    }
};

/// What a binary says about itself in `nerva version --verbose`: the facts a pack compares.
pub const Facts = struct {
    release: Release,
    release_client_min: Release,
    /// 64 lower-case hex digits: `format_digest`.
    format: [64]u8,
    git_commit: [20]u8,

    pub const ParseError = error{
        /// A line of `release`, `release_client_min`, `format` or `commit` is missing or
        /// malformed. `commit none` (a build without its commit) is one.
        FactsMissing,
    };

    pub fn parse(text: []const u8) ParseError!Facts {
        var release: ?Release = null;
        var release_client_min: ?Release = null;
        var format: ?[64]u8 = null;
        var git_commit: ?[20]u8 = null;

        var lines = mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var words = mem.tokenizeScalar(u8, line, ' ');
            const key = words.next() orelse continue;
            const value = words.next() orelse continue;
            if (words.next() != null) continue;
            if (mem.eql(u8, key, "release")) {
                release = Release.parse(value) catch return error.FactsMissing;
            } else if (mem.eql(u8, key, "release_client_min")) {
                release_client_min = Release.parse(value) catch return error.FactsMissing;
            } else if (mem.eql(u8, key, "format")) {
                if (value.len != 64) return error.FactsMissing;
                for (value) |digit| {
                    if (!std.ascii.isDigit(digit) and !(digit >= 'a' and digit <= 'f')) {
                        return error.FactsMissing;
                    }
                }
                format = value[0..64].*;
            } else if (mem.eql(u8, key, "commit")) {
                if (value.len != 40) return error.FactsMissing;
                var binary: [20]u8 = undefined;
                _ = std.fmt.hexToBytes(&binary, value) catch return error.FactsMissing;
                // A build outside a git checkout has the commit 0000...: the header rejects it.
                if (stdx.zeroed(&binary)) return error.FactsMissing;
                git_commit = binary;
            }
        }
        return .{
            .release = release orelse return error.FactsMissing,
            .release_client_min = release_client_min orelse return error.FactsMissing,
            .format = format orelse return error.FactsMissing,
            .git_commit = git_commit orelse return error.FactsMissing,
        };
    }
};

/// Why a past release cannot be bundled (NRV-E0725).
pub const Refusal = enum {
    /// Its release is not lower: a cluster only moves up (`execute_op_upgrade`).
    release_not_lower,
    /// Its format digest differs: the move is an export and an import (P259c).
    format_differs,
    /// This release's `release_client_min` is above the past release: the clients of the past
    /// release would be refused after the switch.
    client_min_above_past,

    pub fn text(refusal_: Refusal) []const u8 {
        return switch (refusal_) {
            .release_not_lower => "its release is not lower than this build's",
            .format_differs => "its format digest differs from this build's: " ++
                "a rolling upgrade needs equal formats, use export and import",
            .client_min_above_past => "this build's release_client_min is above its release: " ++
                "its clients would be refused after the switch",
        };
    }
};

pub fn refusal(current: Facts, past: Facts) ?Refusal {
    if (past.release.value >= current.release.value) return .release_not_lower;
    if (!mem.eql(u8, &past.format, &current.format)) return .format_differs;
    if (current.release_client_min.value > past.release.value) return .client_min_above_past;
    return null;
}

pub const PackError = error{
    /// The result is over `multiversion_binary_platform_size_max` (NRV-E0719).
    SizeMax,
    /// The input is not a little-endian 64-bit ELF with a usable section header table.
    NotElf,
    /// The input already has one of the two sections and cannot be stripped.
    AlreadyPacked,
    OutOfMemory,
};

pub const Past = struct {
    facts: Facts,
    /// The past release's executable, unpacked.
    bytes: []const u8,
};

pub const PackOptions = struct {
    /// Debug builds are bigger, and have their own limit (`multiversion_binary_platform_size_max`).
    debug: bool,
    /// Tests lower it; production is `constants.multiversion_binary_platform_size_max`.
    size_max: u64,
};

pub fn size_max_default(debug: bool) u64 {
    return constants.multiversion_binary_platform_size_max(.{ .macos = false, .debug = debug });
}

/// The sections of `bytes`, or null when it has neither. Errors from `multiversion.parse_elf`
/// other than "not found" are a damaged binary, and so is a section table that names one of the
/// two sections but does not give both: `pack` writes both or neither, so one changed byte in a
/// name or a section header cannot turn a bundle into "no bundle".
fn sections_find(bytes: []align(8) const u8) !?Offsets {
    // `elf.Header.parse` panics on a wrong magic or version byte in this toolchain; a damaged
    // file must be an error, so the identification is checked first.
    const ehdr = try ehdr_read(bytes);
    if (ehdr.e_ident[elf.EI_VERSION] != 1) return error.NotElf;
    const parsed = multiversion.parse_elf(bytes) catch |err| switch (err) {
        error.MultiversionHeaderOrBodyNotFound => {
            if (try bundle_traces(bytes, ehdr)) return error.Damaged;
            return null;
        },
        else => return err,
    };
    const found = switch (builtin.cpu.arch) {
        .x86_64 => parsed.x86_64,
        .aarch64 => parsed.aarch64,
        else => comptime unreachable,
    } orelse {
        if (try bundle_traces(bytes, ehdr)) return error.Damaged;
        return null;
    };
    return .{
        .header_offset = found.header_offset,
        .body_offset = found.body_offset,
        .body_size = found.body_size,
    };
}

/// Whether `bytes` is, or was, a binary `pack` wrote: its tail resembles `trailer` (at least half
/// of its bytes match, so that one changed byte still shows it), or its section name table has
/// either section's name.
fn bundle_traces(bytes: []const u8, ehdr: elf.Elf64_Ehdr) !bool {
    if (bytes.len >= trailer.len) {
        var matching: usize = 0;
        for (bytes[bytes.len - trailer.len ..], trailer) |actual, expected| {
            if (actual == expected) matching += 1;
        }
        if (matching >= trailer.len / 2) return true;
    }
    const shstr = shdr_read(bytes, ehdr, ehdr.e_shstrndx);
    if (shstr.sh_type != elf.SHT_STRTAB) return error.NotElf;
    if (shstr.sh_offset > bytes.len or shstr.sh_size > bytes.len - shstr.sh_offset) {
        return error.NotElf;
    }
    const names = bytes[shstr.sh_offset..][0..shstr.sh_size];
    return mem.indexOf(u8, names, section_header_name) != null or
        mem.indexOf(u8, names, section_body_name) != null;
}

const Offsets = struct { header_offset: u32, body_offset: u32, body_size: u32 };

fn ehdr_read(bytes: []const u8) PackError!elf.Elf64_Ehdr {
    if (builtin.cpu.arch.endian() != .little) return error.NotElf;
    if (bytes.len < @sizeOf(elf.Elf64_Ehdr)) return error.NotElf;
    const ehdr = mem.bytesToValue(elf.Elf64_Ehdr, bytes[0..@sizeOf(elf.Elf64_Ehdr)]);
    if (!mem.eql(u8, ehdr.e_ident[0..4], elf.MAGIC)) return error.NotElf;
    if (ehdr.e_ident[elf.EI_CLASS] != elf.ELFCLASS64) return error.NotElf;
    if (ehdr.e_ident[elf.EI_DATA] != elf.ELFDATA2LSB) return error.NotElf;
    if (ehdr.e_shentsize != @sizeOf(elf.Elf64_Shdr)) return error.NotElf;
    if (ehdr.e_shnum == 0 or ehdr.e_shnum >= elf.SHN_LORESERVE) return error.NotElf;
    if (ehdr.e_shstrndx == elf.SHN_UNDEF or ehdr.e_shstrndx >= ehdr.e_shnum) return error.NotElf;
    const table_end = @as(u64, ehdr.e_shoff) + @as(u64, ehdr.e_shnum) * @sizeOf(elf.Elf64_Shdr);
    if (table_end > bytes.len) return error.NotElf;
    return ehdr;
}

fn shdr_read(bytes: []const u8, ehdr: elf.Elf64_Ehdr, index: usize) elf.Elf64_Shdr {
    assert(index < ehdr.e_shnum);
    const offset = ehdr.e_shoff + index * @sizeOf(elf.Elf64_Shdr);
    return mem.bytesToValue(elf.Elf64_Shdr, bytes[offset..][0..@sizeOf(elf.Elf64_Shdr)]);
}

/// `bytes` of an unpacked executable, with the two sections added: the result opens under
/// `MultiversionOS` and bundles `past`. Allocated with `allocator`; the caller frees it.
pub fn pack(
    allocator: mem.Allocator,
    input: []const u8,
    current: Facts,
    past: Past,
    options: PackOptions,
) PackError![]align(8) u8 {
    assert(refusal(current, past.facts) == null);
    assert(past.bytes.len > 0 and past.bytes.len <= std.math.maxInt(u32));

    const ehdr = try ehdr_read(input);
    const shstr = shdr_read(input, ehdr, ehdr.e_shstrndx);
    if (shstr.sh_type != elf.SHT_STRTAB) return error.NotElf;
    if (shstr.sh_offset + shstr.sh_size > input.len or shstr.sh_size == 0) return error.NotElf;
    const names_old = input[shstr.sh_offset..][0..shstr.sh_size];
    if (names_old[names_old.len - 1] != 0) return error.NotElf;
    if (mem.indexOf(u8, names_old, section_header_name) != null or
        mem.indexOf(u8, names_old, section_body_name) != null) return error.AlreadyPacked;

    const names_extra = section_body_name ++ "\x00" ++ section_header_name ++ "\x00";
    const shdr_count_old: usize = ehdr.e_shnum;
    const names_end = input.len + past.bytes.len + @sizeOf(Header) + names_old.len +
        names_extra.len;
    const total = mem.alignForward(u64, names_end, 8) +
        (shdr_count_old + 2) * @sizeOf(elf.Elf64_Shdr) + trailer.len;
    if (total > options.size_max) return error.SizeMax;

    var out = try std.ArrayListAligned(u8, 8).initCapacity(allocator, @intCast(total));
    errdefer out.deinit();

    out.appendSliceAssumeCapacity(input);
    const body_offset = out.items.len;
    out.appendSliceAssumeCapacity(past.bytes);
    const header_offset = out.items.len;
    out.appendNTimesAssumeCapacity(0, @sizeOf(Header));
    const names_offset = out.items.len;
    out.appendSliceAssumeCapacity(names_old);
    out.appendSliceAssumeCapacity(names_extra);
    out.appendNTimesAssumeCapacity(0, mem.alignForward(usize, out.items.len, 8) - out.items.len);
    const shdrs_offset = out.items.len;

    for (0..shdr_count_old) |index| {
        var shdr = shdr_read(input, ehdr, index);
        if (index == ehdr.e_shstrndx) {
            shdr.sh_offset = names_offset;
            shdr.sh_size = names_old.len + names_extra.len;
        }
        out.appendSliceAssumeCapacity(mem.asBytes(&shdr));
    }
    const section_new = struct {
        fn make(name: u32, offset: u64, size: u64) elf.Elf64_Shdr {
            return .{
                .sh_name = name,
                .sh_type = elf.SHT_PROGBITS,
                .sh_flags = 0, // Not loaded, not writable.
                .sh_addr = 0,
                .sh_offset = offset,
                .sh_size = size,
                .sh_link = 0,
                .sh_info = 0,
                .sh_addralign = 1,
                .sh_entsize = 0,
            };
        }
    }.make;
    const body_shdr = section_new(@intCast(names_old.len), body_offset, past.bytes.len);
    const header_shdr = section_new(
        @intCast(names_old.len + section_body_name.len + 1),
        header_offset,
        @sizeOf(Header),
    );
    out.appendSliceAssumeCapacity(mem.asBytes(&body_shdr));
    out.appendSliceAssumeCapacity(mem.asBytes(&header_shdr));
    out.appendSliceAssumeCapacity(trailer);
    assert(out.items.len == total);

    var ehdr_new = ehdr;
    ehdr_new.e_shoff = shdrs_offset;
    ehdr_new.e_shnum = @intCast(shdr_count_old + 2);
    @memcpy(out.items[0..@sizeOf(elf.Elf64_Ehdr)], mem.asBytes(&ehdr_new));

    // The header: first zero, to checksum the file as `MultiversionOS` will (it zeroes the
    // header in memory), then final.
    // Upstream's header verification demands that a release up to 0.15.4 (all of Nerva's, so
    // far) leaves the commit and `release_client_min` zero: they were added after it.
    const release_old = current.release.value <= (Release.parse("0.15.4") catch unreachable).value;
    var header: Header = .{
        .current_release = current.release.value,
        .current_checksum = multiversion.checksum.checksum(input),
        .current_flags = .{ .debug = options.debug, .visit = true },
        .current_git_commit = if (release_old) @splat(0) else current.git_commit,
        .current_release_client_min = if (release_old) 0 else current.release_client_min.value,
        .checksum_binary_without_header = multiversion.checksum.checksum(out.items),
    };
    header.past.add(.{
        .release = past.facts.release.value,
        .checksum = multiversion.checksum.checksum(past.bytes),
        .size = @intCast(past.bytes.len),
        .flags = .{ .visit = true, .debug = options.debug },
        .git_commit = past.facts.git_commit,
        .release_client_min = past.facts.release_client_min.value,
    });
    const origin: Origin = .{
        .magic = Origin.magic_value,
        .section_headers_offset = ehdr.e_shoff,
    };
    @memcpy(header.reserved[0..@sizeOf(Origin)], mem.asBytes(&origin));
    header.checksum_header = header.calculate_header_checksum();
    header.verify() catch unreachable;
    @memcpy(out.items[header_offset..][0..@sizeOf(Header)], mem.asBytes(&header));

    return out.toOwnedSlice();
}

pub const VerifyError = error{
    /// A header or a checksum does not match: the binary is damaged or was changed.
    Damaged,
    OutOfMemory,
};

pub const Bundle = struct {
    header: Header,
    /// The past release's bytes, in the buffer given to `verify`.
    past: []const u8,
};

/// What `MultiversionOS.target_update` checks, and a little more: the header, the checksum of the
/// whole file with the header zeroed, and the checksum of the past release. `bytes` is written
/// (the header is zeroed, then restored) and must not be shared. Null when the binary has no
/// sections: it bundles nothing.
pub fn verify(bytes: []align(8) u8) VerifyError!?Bundle {
    const offsets = (sections_find(bytes) catch return error.Damaged) orelse return null;
    // In `u64`: the offsets come from the file, and `u32` sums of them would overflow.
    if (@as(u64, offsets.header_offset) + @sizeOf(Header) > bytes.len) return error.Damaged;
    if (@as(u64, offsets.body_offset) + offsets.body_size > bytes.len) return error.Damaged;

    const header_bytes = bytes[offsets.header_offset..][0..@sizeOf(Header)];
    // `init_from_bytes` asserts this field is set before it checksums the header.
    const checksum_file = mem.bytesAsValue(
        u128,
        header_bytes[@offsetOf(Header, "checksum_binary_without_header")..][0..16],
    ).*;
    if (checksum_file == 0) return error.Damaged;
    const header = Header.init_from_bytes(header_bytes) catch return error.Damaged;
    @memset(header_bytes, 0);
    const checksum_actual = multiversion.checksum.checksum(bytes);
    @memcpy(header_bytes, mem.asBytes(&header));
    if (checksum_actual != header.checksum_binary_without_header) return error.Damaged;

    const body = bytes[offsets.body_offset..][0..offsets.body_size];
    header.past.verify_checksums(body) catch return error.Damaged;
    // `releases_bundled_max` (P259): one past release. Read from a file, so not an assertion.
    if (header.past.count != 1) return error.Damaged;
    const past = body[header.past.offsets[0]..][0..header.past.sizes[0]];
    return .{ .header = header, .past = past };
}

/// `bytes` without the two sections: the executable `pack` was given. A binary without them is
/// copied as it is. Null when the bundle is one this packer did not write; `error.Damaged` when
/// it is one it wrote and a check fails.
pub fn strip(allocator: mem.Allocator, bytes: []align(8) const u8) !?[]align(8) u8 {
    // Not an ELF executable (a test's stub), or one without the sections: nothing to take off.
    const found = sections_find(bytes) catch |err| switch (err) {
        error.NotElf => null,
        else => return error.Damaged,
    };
    const offsets = found orelse {
        const copy = try allocator.alignedAlloc(u8, 8, bytes.len);
        @memcpy(copy, bytes);
        return copy;
    };
    if (@as(u64, offsets.header_offset) + @sizeOf(Header) > bytes.len) return error.Damaged;
    const header = Header.init_from_bytes(
        bytes[offsets.header_offset..][0..@sizeOf(Header)],
    ) catch return error.Damaged;
    const origin = mem.bytesToValue(Origin, header.reserved[0..@sizeOf(Origin)]);
    if (!mem.eql(u8, &origin.magic, &Origin.magic_value)) return null;

    // `pack` put the body right after the linked executable.
    const input_size = offsets.body_offset;
    var ehdr = try ehdr_read(bytes);
    ehdr.e_shoff = origin.section_headers_offset;
    ehdr.e_shnum -= 2;
    const out = try allocator.alignedAlloc(u8, 8, input_size);
    @memcpy(out, bytes[0..input_size]);
    @memcpy(out[0..@sizeOf(elf.Elf64_Ehdr)], mem.asBytes(&ehdr));
    if (multiversion.checksum.checksum(out) != header.current_checksum) {
        allocator.free(out);
        return error.Damaged;
    }
    return out;
}

/// The release a packed binary bundles, `none` when it is not packed.
pub fn bundles_text(writer: anytype, bundle: ?Bundle) !void {
    const found = bundle orelse return writer.writeAll("bundles none\n");
    const release: Release = .{ .value = found.header.past.releases[0] };
    try writer.print("bundles {}\n", .{release});
}

const testing = std.testing;

/// A small ELF64 executable, as the linker would write one: a header, a program header (not
/// used), some code, `.shstrtab` and a section header table at the end.
fn elf_make(allocator: mem.Allocator, code: []const u8) ![]align(8) u8 {
    var out = std.ArrayListAligned(u8, 8).init(allocator);
    errdefer out.deinit();
    const names = "\x00.text\x00.shstrtab\x00";
    const code_offset = @sizeOf(elf.Elf64_Ehdr);
    const names_offset = code_offset + code.len;
    const shdrs_offset = mem.alignForward(usize, names_offset + names.len, 8);

    var ehdr = mem.zeroes(elf.Elf64_Ehdr);
    @memcpy(ehdr.e_ident[0..4], elf.MAGIC);
    ehdr.e_ident[elf.EI_CLASS] = elf.ELFCLASS64;
    ehdr.e_ident[elf.EI_DATA] = elf.ELFDATA2LSB;
    ehdr.e_ident[elf.EI_VERSION] = 1;
    ehdr.e_type = elf.ET.EXEC;
    ehdr.e_machine = if (builtin.cpu.arch == .aarch64) elf.EM.AARCH64 else elf.EM.X86_64;
    ehdr.e_version = 1;
    ehdr.e_shoff = shdrs_offset;
    ehdr.e_ehsize = @sizeOf(elf.Elf64_Ehdr);
    ehdr.e_shentsize = @sizeOf(elf.Elf64_Shdr);
    ehdr.e_shnum = 3;
    ehdr.e_shstrndx = 2;
    try out.appendSlice(mem.asBytes(&ehdr));
    try out.appendSlice(code);
    try out.appendSlice(names);
    try out.appendNTimes(0, shdrs_offset - out.items.len);

    var shdrs = [_]elf.Elf64_Shdr{
        mem.zeroes(elf.Elf64_Shdr),
        mem.zeroes(elf.Elf64_Shdr),
        mem.zeroes(elf.Elf64_Shdr),
    };
    shdrs[1].sh_name = 1;
    shdrs[1].sh_type = elf.SHT_PROGBITS;
    shdrs[1].sh_offset = code_offset;
    shdrs[1].sh_size = code.len;
    shdrs[2].sh_name = 7;
    shdrs[2].sh_type = elf.SHT_STRTAB;
    shdrs[2].sh_offset = names_offset;
    shdrs[2].sh_size = names.len;
    try out.appendSlice(mem.sliceAsBytes(&shdrs));
    return out.toOwnedSlice();
}

fn facts_make(release: []const u8, client_min: []const u8, format_digit: u8) Facts {
    return .{
        .release = Release.parse(release) catch unreachable,
        .release_client_min = Release.parse(client_min) catch unreachable,
        .format = @splat(format_digit),
        .git_commit = @splat(0xab),
    };
}

test "bundle: Facts parses what nerva version --verbose prints" {
    const text =
        "Nerva version 0.7.1\n" ++
        "release 0.0.6\n" ++
        "release_client_min 0.0.4\n" ++
        "format " ++ "ab" ** 32 ++ "\n" ++
        "bundles none\n" ++
        "version 0.7.1\n" ++
        "format_epoch 1\n" ++
        "commit " ++ "01" ** 20 ++ "\n" ++
        "commit_keys deduplicate\n";
    const facts = try Facts.parse(text);
    try testing.expect(facts.release.value == (try Release.parse("0.0.6")).value);
    try testing.expect(facts.release_client_min.value == (try Release.parse("0.0.4")).value);
    try testing.expectEqualStrings("ab" ** 32, &facts.format);
    try testing.expectEqual(@as([20]u8, @splat(1)), facts.git_commit);

    // A build without its commit cannot be packed or bundled: the header names it.
    try testing.expectError(error.FactsMissing, Facts.parse(
        "release 0.0.6\nrelease_client_min 0.0.4\nformat " ++ "ab" ** 32 ++ "\ncommit none\n",
    ));
    try testing.expectError(error.FactsMissing, Facts.parse("release 0.0.6\n"));
    // `format` is 64 lower-case hex digits.
    try testing.expectError(error.FactsMissing, Facts.parse(
        "release 0.0.6\nrelease_client_min 0.0.4\nformat " ++ "AB" ** 32 ++ "\ncommit " ++
            "01" ** 20 ++ "\n",
    ));
}

test "bundle: a past release is refused unless it is lower, of one format, and keeps its clients" {
    const current = facts_make("0.0.206", "0.0.4", 'a');
    try testing.expectEqual(@as(?Refusal, null), refusal(current, facts_make("0.0.6", "0.0.4", 'a')));
    try testing.expectEqual(
        @as(?Refusal, .release_not_lower),
        refusal(current, facts_make("0.0.206", "0.0.4", 'a')),
    );
    try testing.expectEqual(
        @as(?Refusal, .release_not_lower),
        refusal(current, facts_make("0.0.250", "0.0.4", 'a')),
    );
    try testing.expectEqual(
        @as(?Refusal, .format_differs),
        refusal(current, facts_make("0.0.6", "0.0.4", 'b')),
    );
    // This release accepts clients from 0.0.7 on; the past release is 0.0.6: its clients are
    // refused after the switch.
    const strict = facts_make("0.0.206", "0.0.7", 'a');
    try testing.expectEqual(
        @as(?Refusal, .client_min_above_past),
        refusal(strict, facts_make("0.0.6", "0.0.4", 'a')),
    );
    // At the bound: client_min equal to the past release is accepted.
    try testing.expectEqual(
        @as(?Refusal, null),
        refusal(facts_make("0.0.206", "0.0.6", 'a'), facts_make("0.0.6", "0.0.4", 'a')),
    );
}

test "bundle: a packed binary verifies, bundles the past release, and strips back exactly" {
    const input = try elf_make(testing.allocator, "current release code");
    defer testing.allocator.free(input);
    const past_bytes = try elf_make(testing.allocator, "past release code");
    defer testing.allocator.free(past_bytes);

    const current = facts_make("0.0.206", "0.0.4", 'a');
    const past: Past = .{ .facts = facts_make("0.0.6", "0.0.4", 'a'), .bytes = past_bytes };
    const packed_bytes = try pack(testing.allocator, input, current, past, .{
        .debug = false,
        .size_max = 1 << 20,
    });
    defer testing.allocator.free(packed_bytes);

    // The linked executable is a prefix: nothing it loads moves.
    try testing.expectEqualSlices(u8, input[@sizeOf(elf.Elf64_Ehdr)..], packed_bytes[@sizeOf(elf.Elf64_Ehdr)..input.len]);

    const buffer = try testing.allocator.alignedAlloc(u8, 8, packed_bytes.len);
    defer testing.allocator.free(buffer);
    @memcpy(buffer, packed_bytes);
    const bundle = (try verify(buffer)).?;
    try testing.expectEqualSlices(u8, past_bytes, bundle.past);
    try testing.expectEqual(@as(u32, 1), bundle.header.past.count);
    try testing.expectEqual(past.facts.release.value, bundle.header.past.releases[0]);
    try testing.expectEqual(current.release.value, bundle.header.current_release);
    // `MultiversionOS` advertises both: it can run the past release and offers the current one.
    const advertised = bundle.header.advertisable(past.facts.release);
    try testing.expectEqual(@as(usize, 2), advertised.slice().len);
    try testing.expectEqual(past.facts.release.value, advertised.slice()[0].value);
    try testing.expectEqual(current.release.value, advertised.slice()[1].value);

    var text: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&text);
    try bundles_text(stream.writer(), bundle);
    try testing.expectEqualStrings("bundles 0.0.6\n", stream.getWritten());
    stream.reset();
    try bundles_text(stream.writer(), null);
    try testing.expectEqualStrings("bundles none\n", stream.getWritten());

    // Stripping gives the linked executable back, byte for byte.
    const stripped = (try strip(testing.allocator, packed_bytes)).?;
    defer testing.allocator.free(stripped);
    try testing.expectEqualSlices(u8, input, stripped);
    // An unpacked binary is its own strip, and bundles nothing.
    const plain = (try strip(testing.allocator, input)).?;
    defer testing.allocator.free(plain);
    try testing.expectEqualSlices(u8, input, plain);
    const input_copy = try testing.allocator.alignedAlloc(u8, 8, input.len);
    defer testing.allocator.free(input_copy);
    @memcpy(input_copy, input);
    try testing.expectEqual(@as(?Bundle, null), try verify(input_copy));
    // Packing a packed binary is refused: strip it first.
    try testing.expectError(error.AlreadyPacked, pack(testing.allocator, packed_bytes, current, past, .{
        .debug = false,
        .size_max = 1 << 20,
    }));
}

test "bundle: one changed byte anywhere in the packed binary is damage" {
    const input = try elf_make(testing.allocator, "current release code");
    defer testing.allocator.free(input);
    const past_bytes = try elf_make(testing.allocator, "past release code");
    defer testing.allocator.free(past_bytes);
    const packed_bytes = try pack(
        testing.allocator,
        input,
        facts_make("0.0.206", "0.0.4", 'a'),
        .{ .facts = facts_make("0.0.6", "0.0.4", 'a'), .bytes = past_bytes },
        .{ .debug = false, .size_max = 1 << 20 },
    );
    defer testing.allocator.free(packed_bytes);

    const buffer = try testing.allocator.alignedAlloc(u8, 8, packed_bytes.len);
    defer testing.allocator.free(buffer);
    // Every byte, one at a time: the code, the past release, the header, the section names and
    // the section headers. The checksum of the whole file covers all of them, and a name or a
    // section header changed so that a section is no longer found is damage too, never "no
    // bundle" (NRV-E0719).
    for (0..packed_bytes.len) |index| {
        @memcpy(buffer, packed_bytes);
        buffer[index] ^= 1;
        testing.expectError(error.Damaged, verify(buffer)) catch |err| {
            std.debug.print("byte {} changed: not damage\n", .{index});
            return err;
        };
    }
}

test "bundle: a result over the size limit is refused, one byte under it is not" {
    const input = try elf_make(testing.allocator, "current release code");
    defer testing.allocator.free(input);
    const past_bytes = try elf_make(testing.allocator, "past release code");
    defer testing.allocator.free(past_bytes);
    const current = facts_make("0.0.206", "0.0.4", 'a');
    const past: Past = .{ .facts = facts_make("0.0.6", "0.0.4", 'a'), .bytes = past_bytes };

    const packed_bytes = try pack(testing.allocator, input, current, past, .{
        .debug = false,
        .size_max = 1 << 20,
    });
    defer testing.allocator.free(packed_bytes);
    const size = packed_bytes.len;

    const at_bound = try pack(testing.allocator, input, current, past, .{
        .debug = false,
        .size_max = size,
    });
    testing.allocator.free(at_bound);
    try testing.expectError(error.SizeMax, pack(testing.allocator, input, current, past, .{
        .debug = false,
        .size_max = size - 1,
    }));
}

test "bundle: a file that is not an ELF executable is refused" {
    const current = facts_make("0.0.206", "0.0.4", 'a');
    const past: Past = .{ .facts = facts_make("0.0.6", "0.0.4", 'a'), .bytes = "x" };
    try testing.expectError(error.NotElf, pack(testing.allocator, "not an executable", current, past, .{
        .debug = false,
        .size_max = 1 << 20,
    }));
}
