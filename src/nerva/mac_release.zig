//! `zig build mac-release` (v0.7.1, slice 3, P284): the macOS release, one universal binary,
//! signed with the owner's Developer ID, zipped and optionally notarized. A host tool: the step
//! in `build.zig` builds it for the machine running the build and runs it twice, `preflight`
//! before anything is compiled and `package` after the two thin binaries exist. It runs only on
//! a Mac, only by the owner (CI runs it ad hoc, `-Dsign-identity=-`).
//!
//! Its failures are tooling messages (one line, `mac-release: ...`), not NRV codes: only the
//! owner runs it, as with the Jepsen suite's messages (P215c). It never reads, prints or logs a
//! secret: the keychain holds them. The parts that decide something are pure functions with
//! unit tests, which run on Linux; the rest is the calls that need a Mac.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;

pub const default_identity = "Developer ID Application: Alex Zuzin (56A872L679)";
pub const default_profile = "nerva-notary";
const release_url = "https://github.com/NervaLog/nerva/releases/download";

/// The longest release version the tool and `-Dversion` accept; every name buffer below is sized
/// from it, so none can overflow.
pub const version_length_max = 40;
pub const archive_stem_max = "nerva-v-universal-macos".len + version_length_max;
pub const tag_max = "v".len + version_length_max;

const codesign_tool = "/usr/bin/codesign";
const ditto_tool = "/usr/bin/ditto";
const lipo_tool = "/usr/bin/lipo";
const security_tool = "/usr/bin/security";
const unzip_tool = "/usr/bin/unzip";
const xcrun_tool = "/usr/bin/xcrun";

/// The two slices of the universal binary, as `codesign --arch` names them.
const slice_archs = [_][]const u8{ "arm64", "x86_64" };

/// The refusals the pure checks return. `message` turns one into its line.
pub const Refusal = enum {
    dirty_tree,
    head_not_tag,
    identity_unknown,
    adhoc_notarize,
    archs_wrong,
    zip_layout_wrong,
    signature_invalid,
    version_line_wrong,
    commit_line_wrong,
    cdhash_missing,
    cdhash_differs,
    not_accepted,
};

pub fn message(refusal: Refusal) []const u8 {
    return switch (refusal) {
        .dirty_tree => "the working tree has uncommitted changes; commit or stash them first",
        .head_not_tag => "HEAD is not the release's tag; check out v<VERSION>",
        .identity_unknown => "the signing identity is not in the keychain " ++
            "(security find-identity -v -p codesigning)",
        .adhoc_notarize => "-Dnotarize needs a Developer ID identity, not the ad hoc one (-)",
        .archs_wrong => "the joined binary is not exactly x86_64 and arm64",
        .zip_layout_wrong => "the zip does not hold exactly <name>/ with nerva, LICENSE and NOTICE",
        .signature_invalid => "codesign -dv does not show the signature this release needs",
        .version_line_wrong => "`nerva version` does not end with the release's version line",
        .commit_line_wrong => "`nerva version`'s first line does not name the tag's commit",
        .cdhash_missing => "codesign -dvvv printed no CDHash",
        .cdhash_differs => "the unzipped binary's CDHash is not the signed binary's",
        .not_accepted => "notarization did not end Accepted",
    };
}

/// `nerva-v<version>-universal-macos`: the directory inside the zip, and the zip's name less its
/// extension.
pub fn archive_stem(buffer: *[archive_stem_max]u8, version: []const u8) []const u8 {
    assert(version_valid(version));
    return std.fmt.bufPrint(buffer, "nerva-v{s}-universal-macos", .{version}) catch unreachable; // Sized from the bound.
}

/// The tag a release is cut from.
pub fn tag_name(buffer: *[tag_max]u8, version: []const u8) []const u8 {
    assert(version_valid(version));
    return std.fmt.bufPrint(buffer, "v{s}", .{version}) catch unreachable; // Sized from the bound.
}

/// The tree must be clean (`git status --porcelain` printed nothing) and HEAD must be the tag
/// (`git tag --points-at HEAD` lists it).
pub fn check_tree(porcelain: []const u8, tags_at_head: []const u8, tag: []const u8) ?Refusal {
    if (std.mem.trim(u8, porcelain, " \r\n").len != 0) return .dirty_tree;
    var lines = std.mem.tokenizeScalar(u8, tags_at_head, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \r"), tag)) return null;
    }
    return .head_not_tag;
}

/// A notarized release needs a Developer ID identity; Apple rejects an ad hoc signature.
pub fn check_notarize(identity: []const u8, notarize: bool) ?Refusal {
    return if (notarize and std.mem.eql(u8, identity, "-")) .adhoc_notarize else null;
}

/// The identity (a quoted name in `security find-identity` output) is listed. `-` is ad hoc and
/// needs none.
pub fn check_identity(listing: []const u8, identity: []const u8) ?Refusal {
    if (std.mem.eql(u8, identity, "-")) return null;
    var quoted_buffer: [256]u8 = undefined;
    const quoted = std.fmt.bufPrint(&quoted_buffer, "\"{s}\"", .{identity}) catch
        return .identity_unknown;
    return if (std.mem.indexOf(u8, listing, quoted) != null) null else .identity_unknown;
}

/// `lipo -archs` of the joined binary: exactly `x86_64` and `arm64`, in either order.
pub fn check_archs(output: []const u8) ?Refusal {
    var seen_x86_64 = false;
    var seen_arm64 = false;
    var count: u32 = 0;
    var words = std.mem.tokenizeAny(u8, output, " \r\n");
    while (words.next()) |word| {
        count += 1;
        if (std.mem.eql(u8, word, "x86_64")) seen_x86_64 = true;
        if (std.mem.eql(u8, word, "arm64")) seen_arm64 = true;
    }
    return if (count == 2 and seen_x86_64 and seen_arm64) null else .archs_wrong;
}

/// The `codesign` arguments that sign `path`: the hardened runtime, no entitlements, a secure
/// timestamp. Ad hoc (`-`) has no timestamp server to ask, so it says `none`.
pub fn codesign_args(
    buffer: *[8][]const u8,
    identity: []const u8,
    path: []const u8,
) []const []const u8 {
    const adhoc = std.mem.eql(u8, identity, "-");
    buffer.* = .{
        codesign_tool,                                    "--force",
        "--options",                                      "runtime",
        if (adhoc) "--timestamp=none" else "--timestamp", "--sign",
        identity,                                         path,
    };
    return buffer;
}

/// `codesign -dvvv` output (it goes to stderr). A Developer ID signature names its authority,
/// the hardened runtime flag and a timestamp; an ad hoc one says `Signature=adhoc` and the same
/// flag.
pub fn check_signature(output: []const u8, adhoc: bool) ?Refusal {
    const runtime = std.mem.indexOf(u8, output, "runtime)") != null;
    if (!runtime) return .signature_invalid;
    if (adhoc) {
        return if (std.mem.indexOf(u8, output, "Signature=adhoc") != null)
            null
        else
            .signature_invalid;
    }
    const authority = std.mem.indexOf(u8, output, "Authority=Developer ID Application") != null;
    const timestamp = std.mem.indexOf(u8, output, "Timestamp=") != null;
    return if (authority and timestamp) null else .signature_invalid;
}

/// The first `CDHash=` value of `codesign -dvvv` output.
pub fn cdhash_parse(output: []const u8) ?[]const u8 {
    const key = "CDHash=";
    const start = std.mem.indexOf(u8, output, key) orelse return null;
    const rest = output[start + key.len ..];
    const end = std.mem.indexOfAny(u8, rest, " \r\n") orelse rest.len;
    const hash = rest[0..end];
    if (hash.len == 0) return null;
    for (hash) |byte| if (!std.ascii.isHex(byte)) return null;
    return hash;
}

pub fn check_cdhash(signed_output: []const u8, unzipped_output: []const u8) ?Refusal {
    const signed = cdhash_parse(signed_output) orelse return .cdhash_missing;
    const unzipped = cdhash_parse(unzipped_output) orelse return .cdhash_missing;
    return if (std.mem.eql(u8, signed, unzipped)) null else .cdhash_differs;
}

/// `nerva version` of the signed binary: the first line carries `+<short commit>` (the tag's),
/// and the release line `version <version>` is among the rest.
pub fn check_version_output(
    output: []const u8,
    short_commit: []const u8,
    version: []const u8,
) ?Refusal {
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    const first = lines.next() orelse return .commit_line_wrong;
    var suffix_buffer: [version_length_max + 8]u8 = undefined;
    const suffix = std.fmt.bufPrint(&suffix_buffer, "+{s}", .{short_commit}) catch
        return .commit_line_wrong;
    if (std.mem.indexOf(u8, first, suffix) == null) return .commit_line_wrong;
    var line_buffer: [version_length_max + 8]u8 = undefined;
    const wanted = std.fmt.bufPrint(&line_buffer, "version {s}", .{version}) catch
        return .version_line_wrong;
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trimRight(u8, line, "\r"), wanted)) return null;
    }
    return .version_line_wrong;
}

/// `unzip -Z1` of the release zip: exactly `<stem>/` (optional entry) and the three files in it,
/// and nothing else (no `__MACOSX`, no AppleDouble `._` entries).
pub fn check_zip_listing(listing: []const u8, stem: []const u8) ?Refusal {
    const names = [_][]const u8{ "nerva", "LICENSE", "NOTICE" };
    var seen = [_]bool{false} ** names.len;
    var lines = std.mem.tokenizeAny(u8, listing, "\r\n");
    while (lines.next()) |line| {
        if (line.len == stem.len + 1 and std.mem.startsWith(u8, line, stem) and
            line[stem.len] == '/') continue;
        if (!std.mem.startsWith(u8, line, stem)) return .zip_layout_wrong;
        if (line.len <= stem.len + 1 or line[stem.len] != '/') return .zip_layout_wrong;
        const entry = line[stem.len + 1 ..];
        const index = for (names, 0..) |name, at| {
            if (std.mem.eql(u8, entry, name)) break at;
        } else return .zip_layout_wrong;
        if (seen[index]) return .zip_layout_wrong;
        seen[index] = true;
    }
    for (seen) |present| if (!present) return .zip_layout_wrong;
    return null;
}

/// `notarytool submit --wait` ends with `status: Accepted` or another status (`Invalid`).
pub fn check_notary(output: []const u8) ?Refusal {
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    var accepted = false;
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (std.mem.startsWith(u8, trimmed, "status: ")) {
            accepted = std.mem.eql(u8, trimmed["status: ".len..], "Accepted");
        }
    }
    return if (accepted) null else .not_accepted;
}

/// The Homebrew formula: the template with `@VERSION@`, `@URL@` and `@SHA256@` replaced.
pub fn formula_fill(
    gpa: std.mem.Allocator,
    template: []const u8,
    version: []const u8,
    url: []const u8,
    sha256: []const u8,
) ![]u8 {
    const placeholders = [_][]const u8{ "@VERSION@", "@URL@", "@SHA256@" };
    const values = [_][]const u8{ version, url, sha256 };
    var text = try gpa.dupe(u8, template);
    errdefer gpa.free(text);
    inline for (placeholders, values) |placeholder, value| {
        const next = try std.mem.replaceOwned(u8, gpa, text, placeholder, value);
        gpa.free(text);
        text = next;
    }
    for (placeholders) |placeholder| {
        if (std.mem.indexOf(u8, text, placeholder) != null) return error.PlaceholderLeft;
    }
    return text;
}

/// A release's version: `[0-9]+.[0-9]+.[0-9]+` with an optional `-[0-9A-Za-z.]+` suffix, at most
/// `version_length_max` bytes. `build.zig` checks `-Dversion` with it, so no other string reaches
/// `nerva version`.
pub fn version_valid(version: []const u8) bool {
    if (version.len == 0 or version.len > version_length_max) return false;
    var rest = version;
    for (0..3) |part| {
        var digits: usize = 0;
        while (digits < rest.len and std.ascii.isDigit(rest[digits])) digits += 1;
        if (digits == 0) return false;
        rest = rest[digits..];
        if (part < 2) {
            if (rest.len == 0 or rest[0] != '.') return false;
            rest = rest[1..];
        }
    }
    if (rest.len == 0) return true;
    if (rest[0] != '-' or rest.len == 1) return false;
    for (rest[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '.') return false;
    }
    return true;
}

// ---------------------------------------------------------------------------------------------
// The calls that need a Mac.

const Options = struct {
    mode: enum { preflight, package },
    version: []const u8,
    identity: []const u8 = default_identity,
    profile: []const u8 = default_profile,
    notarize: bool = false,
    root: []const u8 = ".",
    out: []const u8 = "zig-out/mac-release",
    template: []const u8 = "packaging/homebrew/nerva.rb",
    arm64: []const u8 = "",
    x86_64: []const u8 = "",
};

fn fail(comptime format: []const u8, args: anytype) noreturn {
    std.io.getStdErr().writer().print("mac-release: " ++ format ++ "\n", args) catch {};
    std.process.exit(1);
}

fn refuse(refusal: Refusal) noreturn {
    fail("{s}", .{message(refusal)});
}

const Output = struct { stdout: []u8, stderr: []u8 };

/// Runs `argv` in `cwd`; any exit but 0 ends the tool with `what` and the program's last words.
fn run(gpa: std.mem.Allocator, cwd: []const u8, argv: []const []const u8, what: []const u8) Output {
    const result = std.process.Child.run(.{
        .allocator = gpa,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = 1 << 20,
    }) catch |err| switch (err) {
        error.FileNotFound => fail(
            "{s}: {s} is not installed (xcode-select --install)",
            .{ what, argv[0] },
        ),
        else => fail("{s}: cannot run {s}", .{ what, argv[0] }),
    };
    const code: u32 = switch (result.term) {
        .Exited => |code| code,
        else => 255,
    };
    if (code != 0) {
        if (std.mem.indexOf(u8, result.stderr, "errSecInternalComponent") != null) {
            fail("{s}: codesign cannot reach the keychain (errSecInternalComponent); " ++
                "run this from a Terminal on the Mac's own desktop, not over ssh", .{what});
        }
        const tail = std.mem.trim(u8, result.stderr, " \r\n");
        const last = tail[if (std.mem.lastIndexOfScalar(u8, tail, '\n')) |at| at + 1 else 0..];
        fail("{s}: {s} failed ({}): {s}", .{ what, argv[0], code, last });
    }
    return .{ .stdout = result.stdout, .stderr = result.stderr };
}

fn parse_options(gpa: std.mem.Allocator) Options {
    const args = std.process.argsAlloc(gpa) catch @panic("OOM");
    if (args.len < 2) fail("usage: mac_release preflight|package --version V [options]", .{});
    var options: Options = .{ .mode = undefined, .version = "" };
    if (std.mem.eql(u8, args[1], "preflight")) {
        options.mode = .preflight;
    } else if (std.mem.eql(u8, args[1], "package")) {
        options.mode = .package;
    } else {
        fail("unknown mode '{s}'", .{args[1]});
    }
    var index: usize = 2;
    while (index < args.len) : (index += 1) {
        const flag = args[index];
        if (std.mem.eql(u8, flag, "--notarize")) {
            options.notarize = true;
            continue;
        }
        index += 1;
        if (index == args.len) fail("{s} needs a value", .{flag});
        const field = value_field(&options, flag) orelse fail("unknown option {s}", .{flag});
        field.* = args[index];
    }
    if (!version_valid(options.version)) {
        fail("--version '{s}' is not a version", .{options.version});
    }
    return options;
}

fn value_field(options: *Options, flag: []const u8) ?*[]const u8 {
    const names = .{
        .{ "--version", "version" }, .{ "--identity", "identity" },
        .{ "--profile", "profile" }, .{ "--root", "root" },
        .{ "--out", "out" },         .{ "--template", "template" },
        .{ "--arm64", "arm64" },     .{ "--x86_64", "x86_64" },
    };
    inline for (names) |name| {
        if (std.mem.eql(u8, flag, name[0])) return &@field(options, name[1]);
    }
    return null;
}

pub fn main() !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const gpa = arena_state.allocator();
    if (builtin.os.tag != .macos) fail("this step runs on a Mac (codesign, lipo, ditto)", .{});
    const options = parse_options(gpa);
    switch (options.mode) {
        .preflight => preflight(gpa, options),
        .package => package(gpa, options),
    }
}

/// Refuses before anything is built or signed.
fn preflight(gpa: std.mem.Allocator, options: Options) void {
    if (check_notarize(options.identity, options.notarize)) |refusal| refuse(refusal);
    var tag_buffer: [tag_max]u8 = undefined;
    const tag = tag_name(&tag_buffer, options.version);
    const status = run(gpa, options.root, &.{ "git", "status", "--porcelain" }, "git");
    const tags = run(gpa, options.root, &.{ "git", "tag", "--points-at", "HEAD" }, "git");
    if (check_tree(status.stdout, tags.stdout, tag)) |refusal| refuse(refusal);
    if (std.mem.eql(u8, options.identity, "-")) return;
    const listing = run(gpa, options.root, &.{
        security_tool, "find-identity", "-v", "-p", "codesigning",
    }, "security");
    if (check_identity(listing.stdout, options.identity)) |refusal| refuse(refusal);
    // The profile holds the notary credentials; this only asks Apple whether it works.
    _ = run(gpa, options.root, &.{
        xcrun_tool, "notarytool", "history", "--keychain-profile", options.profile,
    }, "the notary profile");
}

fn join(gpa: std.mem.Allocator, parts: []const []const u8) []u8 {
    return std.fs.path.join(gpa, parts) catch @panic("OOM");
}

fn print(gpa: std.mem.Allocator, comptime format: []const u8, args: anytype) []u8 {
    return std.fmt.allocPrint(gpa, format, args) catch @panic("OOM");
}

/// What went wrong with a file, in words; never the error's own name.
fn file_problem(err: anyerror) []const u8 {
    return switch (err) {
        error.FileNotFound => "it does not exist",
        error.AccessDenied, error.PermissionDenied => "permission denied",
        error.NoSpaceLeft => "the disk is full",
        error.FileTooBig => "it is too large",
        else => "the operating system refused",
    };
}

fn fail_at(what: []const u8, path: []const u8, err: anyerror) noreturn {
    fail("cannot {s} {s}: {s}", .{ what, path, file_problem(err) });
}

/// `path` made absolute against `base` (itself absolute), without touching the disk.
fn absolute(gpa: std.mem.Allocator, base: []const u8, path: []const u8) []u8 {
    assert(std.fs.path.isAbsolute(base));
    const result = std.fs.path.resolve(gpa, &.{ base, path }) catch @panic("OOM");
    assert(std.fs.path.isAbsolute(result));
    return result;
}

/// Every path in `options` absolute (#328). `run` starts programs in other directories
/// (`out`, `root`), so a relative path would be read there, not where it was given; the
/// thin binaries are relative to this process's directory, the rest to `root`.
fn absolute_options(gpa: std.mem.Allocator, options: Options) Options {
    const here = std.fs.cwd().realpathAlloc(gpa, ".") catch |err| fail_at("resolve", ".", err);
    var result = options;
    result.root = std.fs.cwd().realpathAlloc(gpa, options.root) catch |err|
        fail_at("resolve", options.root, err);
    result.out = absolute(gpa, result.root, options.out);
    result.template = absolute(gpa, result.root, options.template);
    result.arm64 = absolute(gpa, here, options.arm64);
    result.x86_64 = absolute(gpa, here, options.x86_64);
    return result;
}

fn package(gpa: std.mem.Allocator, options_given: Options) void {
    const options = absolute_options(gpa, options_given);
    const out = options.out;
    std.fs.cwd().deleteTree(out) catch |err| fail_at("empty", out, err);
    var stem_buffer: [archive_stem_max]u8 = undefined;
    const stem = archive_stem(&stem_buffer, options.version);
    const stage = join(gpa, &.{ out, stem });
    std.fs.cwd().makePath(stage) catch |err| fail_at("make", stage, err);
    const binary = join(gpa, &.{ stage, "nerva" });

    const lipo_args = [_][]const u8{
        lipo_tool, "-create", "-output", binary, options.arm64, options.x86_64,
    };
    _ = run(gpa, out, &lipo_args, "lipo");
    const archs = run(gpa, out, &.{ lipo_tool, "-archs", binary }, "lipo");
    if (check_archs(archs.stdout)) |refusal| refuse(refusal);

    sign_and_verify(gpa, out, options, binary);
    run_signed(gpa, options, binary);

    for ([_][]const u8{ "LICENSE", "NOTICE" }) |name| {
        const from = join(gpa, &.{ options.root, name });
        const to = join(gpa, &.{ stage, name });
        std.fs.cwd().copyFile(from, std.fs.cwd(), to, .{}) catch |err| fail_at("copy", from, err);
    }
    const zip_name = print(gpa, "{s}.zip", .{stem});
    const zip = join(gpa, &.{ out, zip_name });
    _ = run(gpa, out, &.{
        ditto_tool, "-c", "-k", "--norsrc", "--keepParent", stage, zip,
    }, "ditto");
    const listing = run(gpa, out, &.{ unzip_tool, "-Z1", zip }, "unzip");
    if (check_zip_listing(listing.stdout, stem)) |refusal| refuse(refusal);
    check_unzipped(gpa, out, zip, binary);
    const sha = write_checksum(gpa, zip, zip_name);

    if (options.notarize) {
        const submitted = run(gpa, out, &.{
            xcrun_tool, "notarytool", "submit", zip, "--keychain-profile", options.profile, "--wait",
        }, "notarytool");
        if (check_notary(submitted.stdout)) |refusal| refuse(refusal);
    }
    write_formula(gpa, options, stem, sha, out);
    std.io.getStdOut().writer().print("mac-release: {s} ({s})\n", .{ zip, sha }) catch {};
}

fn sign_and_verify(
    gpa: std.mem.Allocator,
    cwd: []const u8,
    options: Options,
    binary: []const u8,
) void {
    var argv_buffer: [8][]const u8 = undefined;
    _ = run(gpa, cwd, codesign_args(&argv_buffer, options.identity, binary), "codesign");
    _ = run(gpa, cwd, &.{ codesign_tool, "--verify", "--strict", binary }, "codesign --verify");
    // `codesign -d` describes one slice of a universal binary (the host's, unless `--arch`
    // says), so each slice is verified and described on its own.
    const adhoc = std.mem.eql(u8, options.identity, "-");
    for (slice_archs) |arch| {
        _ = run(gpa, cwd, &.{
            codesign_tool, "--verify", "--strict", "--arch", arch, binary,
        }, "codesign --verify");
        const shown = run(gpa, cwd, &.{
            codesign_tool, "-dvvv", "--arch", arch, binary,
        }, "codesign -dv");
        // `codesign -d` writes to stderr.
        if (check_signature(shown.stderr, adhoc)) |refusal| refuse(refusal);
    }
}

/// The signed binary runs, and the hardened runtime does not break `format`.
fn run_signed(gpa: std.mem.Allocator, options: Options, binary: []const u8) void {
    const commit = run(gpa, options.root, &.{ "git", "rev-parse", "HEAD" }, "git");
    // The binary's `+<commit>` is the first 7 characters; `--short=7` may be longer.
    const short = std.mem.trim(u8, commit.stdout, " \r\n")[0..7];
    const version = run(gpa, options.root, &.{ binary, "version" }, "nerva version");
    if (check_version_output(version.stdout, short, options.version)) |refusal| refuse(refusal);
    const directory = join(gpa, &.{ std.fs.path.dirname(binary).?, ".format" });
    std.fs.cwd().makePath(directory) catch |err| fail_at("make", directory, err);
    defer std.fs.cwd().deleteTree(directory) catch {};
    const file = join(gpa, &.{ directory, "0_0.nerva" });
    _ = run(gpa, directory, &.{
        binary,          "format", "--cluster=0", "--replica=0", "--replica-count=1",
        "--development", file,
    }, "nerva format");
}

fn check_unzipped(
    gpa: std.mem.Allocator,
    out: []const u8,
    zip: []const u8,
    binary: []const u8,
) void {
    const unzipped_dir = join(gpa, &.{ out, ".unzipped" });
    defer std.fs.cwd().deleteTree(unzipped_dir) catch {};
    std.fs.cwd().makePath(unzipped_dir) catch |err| fail_at("make", unzipped_dir, err);
    _ = run(gpa, out, &.{ ditto_tool, "-x", "-k", zip, unzipped_dir }, "ditto");
    const name = std.fs.path.basename(zip);
    const copy = join(gpa, &.{ unzipped_dir, name[0 .. name.len - ".zip".len], "nerva" });
    for (slice_archs) |arch| {
        const signed = run(gpa, out, &.{
            codesign_tool, "-dvvv", "--arch", arch, binary,
        }, "codesign -dv");
        const unzipped = run(gpa, out, &.{
            codesign_tool, "-dvvv", "--arch", arch, copy,
        }, "codesign -dv");
        if (check_cdhash(signed.stderr, unzipped.stderr)) |refusal| refuse(refusal);
    }
}

/// `<zip>.sha256` as `sha256sum` and `shasum -c` read it; returns the hex digest.
fn write_checksum(gpa: std.mem.Allocator, zip: []const u8, zip_name: []const u8) []const u8 {
    const bytes = std.fs.cwd().readFileAlloc(gpa, zip, 1 << 30) catch |err|
        fail_at("read", zip, err);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    const hex = print(gpa, "{}", .{std.fmt.fmtSliceHexLower(&digest)});
    const path = print(gpa, "{s}.sha256", .{zip});
    const line = print(gpa, "{s}  {s}\n", .{ hex, zip_name });
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = line }) catch |err|
        fail_at("write", path, err);
    return hex;
}

fn write_formula(
    gpa: std.mem.Allocator,
    options: Options,
    stem: []const u8,
    sha: []const u8,
    out: []const u8,
) void {
    const template_path = options.template;
    const template = std.fs.cwd().readFileAlloc(gpa, template_path, 1 << 20) catch |err|
        fail_at("read", template_path, err);
    const url = print(gpa, "{s}/v{s}/{s}.zip", .{ release_url, options.version, stem });
    const filled = formula_fill(gpa, template, options.version, url, sha) catch |err| switch (err) {
        error.PlaceholderLeft => fail(
            "cannot fill the formula: the template has a placeholder this tool does not know",
            .{},
        ),
        error.OutOfMemory => fail("cannot fill the formula: out of memory", .{}),
    };
    const path = join(gpa, &.{ out, "nerva.rb" });
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = filled }) catch |err|
        fail_at("write", path, err);
}

test "absolute makes relative paths absolute against the base and keeps absolute ones" {
    const gpa = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "zig-out/mac-release", "/work/repo/zig-out/mac-release" },
        .{ "../.zig-cache/o/abc/nerva", "/work/.zig-cache/o/abc/nerva" },
        .{ "/elsewhere/nerva", "/elsewhere/nerva" },
    };
    for (cases) |case| {
        const got = absolute(gpa, "/work/repo", case[0]);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(case[1], got);
    }
}

test "absolute_options leaves no relative path for run to double" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const options = absolute_options(arena.allocator(), .{
        .mode = .package,
        .version = "0.7.1",
        .arm64 = ".zig-cache/o/a/nerva",
        .x86_64 = ".zig-cache/o/b/nerva",
    });
    for ([_][]const u8{
        options.root, options.out, options.template, options.arm64, options.x86_64,
    }) |path| try std.testing.expect(std.fs.path.isAbsolute(path));
    try std.testing.expect(std.mem.startsWith(u8, options.out, options.root));
}

test "archive and tag names" {
    var stem_buffer: [archive_stem_max]u8 = undefined;
    var tag_buffer: [tag_max]u8 = undefined;
    try std.testing.expectEqualStrings(
        "nerva-v0.7.1-universal-macos",
        archive_stem(&stem_buffer, "0.7.1"),
    );
    try std.testing.expectEqualStrings("v0.7.1", tag_name(&tag_buffer, "0.7.1"));
    const longest = "1.2.3-" ++ "a" ** (version_length_max - 6);
    try std.testing.expectEqual(version_length_max, longest.len);
    try std.testing.expect(archive_stem(&stem_buffer, longest).len == archive_stem_max);
    try std.testing.expect(tag_name(&tag_buffer, longest).len == tag_max);
}

test "check_tree refuses a dirty tree and a HEAD that is not the tag" {
    try std.testing.expectEqual(@as(?Refusal, null), check_tree("", "v0.7.1\n", "v0.7.1"));
    try std.testing.expectEqual(
        @as(?Refusal, null),
        check_tree("\n", "v0.7.0\nv0.7.1\n", "v0.7.1"),
    );
    try std.testing.expectEqual(
        @as(?Refusal, .dirty_tree),
        check_tree(" M build.zig\n", "v0.7.1\n", "v0.7.1"),
    );
    try std.testing.expectEqual(@as(?Refusal, .head_not_tag), check_tree("", "", "v0.7.1"));
    try std.testing.expectEqual(
        @as(?Refusal, .head_not_tag),
        check_tree("", "v0.7.10\n", "v0.7.1"),
    );
}

test "check_identity" {
    const listing =
        \\  1) ABCDEF "Developer ID Application: Alex Zuzin (56A872L679)"
        \\     1 valid identities found
    ;
    try std.testing.expectEqual(@as(?Refusal, null), check_identity(listing, default_identity));
    try std.testing.expectEqual(@as(?Refusal, null), check_identity("", "-"));
    try std.testing.expectEqual(@as(?Refusal, .identity_unknown), check_identity(listing, "Other"));
}

test "check_archs wants x86_64 and arm64, either order" {
    try std.testing.expectEqual(@as(?Refusal, null), check_archs("x86_64 arm64\n"));
    try std.testing.expectEqual(@as(?Refusal, null), check_archs("arm64 x86_64\n"));
    try std.testing.expectEqual(@as(?Refusal, .archs_wrong), check_archs("arm64\n"));
    try std.testing.expectEqual(@as(?Refusal, .archs_wrong), check_archs("x86_64 arm64 arm64e\n"));
    try std.testing.expectEqual(@as(?Refusal, .archs_wrong), check_archs(""));
}

test "codesign_args for an identity and for ad hoc" {
    var buffer: [8][]const u8 = undefined;
    const identity = codesign_args(&buffer, default_identity, "/x/nerva");
    try std.testing.expectEqualSlices([]const u8, &.{
        codesign_tool, "--force", "--options",      "runtime",
        "--timestamp", "--sign",  default_identity, "/x/nerva",
    }, identity);
    const adhoc = codesign_args(&buffer, "-", "/x/nerva");
    try std.testing.expectEqualSlices([]const u8, &.{
        codesign_tool,      "--force", "--options", "runtime",
        "--timestamp=none", "--sign",  "-",         "/x/nerva",
    }, adhoc);
}

test "check_signature: Developer ID and ad hoc" {
    const developer =
        \\Executable=/x/nerva
        \\Identifier=nerva
        \\CodeDirectory v=20500 size=1 flags=0x10000(runtime) hashes=1+2 location=embedded
        \\Authority=Developer ID Application: Alex Zuzin (56A872L679)
        \\Timestamp=Nov 10, 2026 at 10:00:00
    ;
    try std.testing.expectEqual(@as(?Refusal, null), check_signature(developer, false));
    try std.testing.expectEqual(
        @as(?Refusal, .signature_invalid),
        check_signature(developer, true),
    );
    const no_timestamp = "flags=0x10000(runtime)\nAuthority=Developer ID Application: A\n";
    try std.testing.expectEqual(
        @as(?Refusal, .signature_invalid),
        check_signature(no_timestamp, false),
    );
    const no_runtime = "flags=0x0(none)\nAuthority=Developer ID Application: A\nTimestamp=x\n";
    try std.testing.expectEqual(
        @as(?Refusal, .signature_invalid),
        check_signature(no_runtime, false),
    );
    const adhoc = "CodeDirectory v=20500 flags=0x10002(adhoc,runtime) hashes=1\nSignature=adhoc\n";
    try std.testing.expectEqual(@as(?Refusal, null), check_signature(adhoc, true));
    try std.testing.expectEqual(@as(?Refusal, .signature_invalid), check_signature(adhoc, false));
}

test "cdhash_parse and check_cdhash" {
    const output = "Identifier=nerva\nCDHash=0123abcdef\nSignature size=9\n";
    try std.testing.expectEqualStrings("0123abcdef", cdhash_parse(output).?);
    try std.testing.expect(cdhash_parse("no hash here") == null);
    try std.testing.expect(cdhash_parse("CDHash=\n") == null);
    try std.testing.expect(cdhash_parse("CDHash=xyz\n") == null);
    try std.testing.expectEqual(@as(?Refusal, null), check_cdhash(output, output));
    try std.testing.expectEqual(
        @as(?Refusal, .cdhash_differs),
        check_cdhash(output, "CDHash=ffff\n"),
    );
    try std.testing.expectEqual(@as(?Refusal, .cdhash_missing), check_cdhash(output, ""));
}

test "check_version_output wants the tag's commit and the version line" {
    const output = "Nerva version 0.0.6+abc1234\nrelease 0.0.6\nbundles none\nversion 0.7.1\n";
    try std.testing.expectEqual(
        @as(?Refusal, null),
        check_version_output(output, "abc1234", "0.7.1"),
    );
    try std.testing.expectEqual(
        @as(?Refusal, .commit_line_wrong),
        check_version_output(output, "def5678", "0.7.1"),
    );
    try std.testing.expectEqual(
        @as(?Refusal, .version_line_wrong),
        check_version_output(output, "abc1234", "0.7.2"),
    );
    try std.testing.expectEqual(
        @as(?Refusal, .commit_line_wrong),
        check_version_output("", "abc1234", "0.7.1"),
    );
}

test "check_notary" {
    const accepted = "Conducting pre-submission checks\n  id: x\n  status: Accepted\n";
    try std.testing.expectEqual(@as(?Refusal, null), check_notary(accepted));
    try std.testing.expectEqual(@as(?Refusal, .not_accepted), check_notary("  status: Invalid\n"));
    try std.testing.expectEqual(@as(?Refusal, .not_accepted), check_notary(""));
}

test "formula_fill replaces every placeholder and refuses a stray one" {
    const gpa = std.testing.allocator;
    const template = "url \"@URL@\"\nversion \"@VERSION@\"\nsha256 \"@SHA256@\"\n# @VERSION@\n";
    const filled = try formula_fill(gpa, template, "0.7.1", "https://x/y.zip", "ab12");
    defer gpa.free(filled);
    try std.testing.expectEqualStrings(
        "url \"https://x/y.zip\"\nversion \"0.7.1\"\nsha256 \"ab12\"\n# 0.7.1\n",
        filled,
    );
    try std.testing.expectError(
        error.PlaceholderLeft,
        formula_fill(gpa, "@OTHER@ @VERSION@ @URL@ @SHA256@", "1.0.0", "u", "@URL@"),
    );
}

test "version_valid" {
    try std.testing.expect(version_valid("0.7.1"));
    try std.testing.expect(version_valid("0.8.0-rc.1"));
    try std.testing.expect(!version_valid(""));
    try std.testing.expect(!version_valid("0.7"));
    try std.testing.expect(!version_valid("v0.7.1"));
    try std.testing.expect(!version_valid("0.7.1+abc"));
    try std.testing.expect(version_valid("10.20.30"));
    try std.testing.expect(!version_valid("0.7.1-"));
    try std.testing.expect(!version_valid("0.7.1\n"));
    try std.testing.expect(!version_valid("x\nformat bogus"));
    try std.testing.expect(!version_valid("0.7.1-rc 1"));
    try std.testing.expect(!version_valid("0..1"));
    try std.testing.expect(!version_valid(".7.1"));
}

test "version_valid is bounded" {
    const at_bound = "1.2.3-" ++ "a" ** (version_length_max - 6);
    try std.testing.expect(version_valid(at_bound));
    try std.testing.expect(!version_valid(at_bound ++ "a"));
}

test "check_notarize refuses ad hoc" {
    try std.testing.expectEqual(@as(?Refusal, .adhoc_notarize), check_notarize("-", true));
    try std.testing.expectEqual(@as(?Refusal, null), check_notarize("-", false));
    try std.testing.expectEqual(@as(?Refusal, null), check_notarize(default_identity, true));
}

test "check_zip_listing wants exactly the stem with its three files" {
    const stem = "nerva-v0.7.1-universal-macos";
    const good = stem ++ "/\n" ++ stem ++ "/nerva\n" ++ stem ++ "/LICENSE\n" ++ stem ++ "/NOTICE\n";
    try std.testing.expectEqual(@as(?Refusal, null), check_zip_listing(good, stem));
    try std.testing.expectEqual(
        @as(?Refusal, null),
        check_zip_listing(stem ++ "/nerva\n" ++ stem ++ "/NOTICE\n" ++ stem ++ "/LICENSE\n", stem),
    );
    try std.testing.expectEqual(
        @as(?Refusal, .zip_layout_wrong),
        check_zip_listing(good ++ "__MACOSX/\n__MACOSX/" ++ stem ++ "/._nerva\n", stem),
    );
    try std.testing.expectEqual(
        @as(?Refusal, .zip_layout_wrong),
        check_zip_listing(good ++ stem ++ "/._nerva\n", stem),
    );
    try std.testing.expectEqual(
        @as(?Refusal, .zip_layout_wrong),
        check_zip_listing(stem ++ "/nerva\n" ++ stem ++ "/LICENSE\n", stem),
    );
    try std.testing.expectEqual(
        @as(?Refusal, .zip_layout_wrong),
        check_zip_listing(good ++ stem ++ "/nerva\n", stem),
    );
    try std.testing.expectEqual(
        @as(?Refusal, .zip_layout_wrong),
        check_zip_listing(stem ++ "x/nerva\n", stem),
    );
}
