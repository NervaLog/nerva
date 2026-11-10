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

/// The refusals the pure checks return. `message` turns one into its line.
pub const Refusal = enum {
    dirty_tree,
    head_not_tag,
    identity_unknown,
    archs_wrong,
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
        .archs_wrong => "the joined binary is not exactly x86_64 and arm64",
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
pub fn archive_stem(buffer: []u8, version: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "nerva-v{s}-universal-macos", .{version}) catch unreachable;
}

/// The tag a release is cut from.
pub fn tag_name(buffer: []u8, version: []const u8) []const u8 {
    return std.fmt.bufPrint(buffer, "v{s}", .{version}) catch unreachable;
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
    buffer: *[9][]const u8,
    identity: []const u8,
    path: []const u8,
) []const []const u8 {
    const adhoc = std.mem.eql(u8, identity, "-");
    buffer.* = .{
        "codesign",                                       "--force",
        "--options",                                      "runtime",
        if (adhoc) "--timestamp=none" else "--timestamp", "--sign",
        identity,                                         path,
        "",
    };
    return buffer[0..8];
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
    var suffix_buffer: [64]u8 = undefined;
    const suffix = std.fmt.bufPrint(&suffix_buffer, "+{s}", .{short_commit}) catch
        return .commit_line_wrong;
    if (std.mem.indexOf(u8, first, suffix) == null) return .commit_line_wrong;
    var line_buffer: [64]u8 = undefined;
    const wanted = std.fmt.bufPrint(&line_buffer, "version {s}", .{version}) catch
        return .version_line_wrong;
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trimRight(u8, line, "\r"), wanted)) return null;
    }
    return .version_line_wrong;
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

/// A release's version: `major.minor.patch` with an optional `-prerelease`, as `release.yml`
/// checks it.
pub fn version_valid(version: []const u8) bool {
    const parsed = std.SemanticVersion.parse(version) catch return false;
    return parsed.build == null;
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
    }) catch |err| fail("{s}: cannot run {s}: {s}", .{ what, argv[0], @errorName(err) });
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
    var tag_buffer: [64]u8 = undefined;
    const tag = tag_name(&tag_buffer, options.version);
    const status = run(gpa, options.root, &.{ "git", "status", "--porcelain" }, "git");
    const tags = run(gpa, options.root, &.{ "git", "tag", "--points-at", "HEAD" }, "git");
    if (check_tree(status.stdout, tags.stdout, tag)) |refusal| refuse(refusal);
    if (std.mem.eql(u8, options.identity, "-")) return;
    const listing = run(gpa, options.root, &.{
        "security", "find-identity", "-v", "-p", "codesigning",
    }, "security");
    if (check_identity(listing.stdout, options.identity)) |refusal| refuse(refusal);
    // The profile holds the notary credentials; this only asks Apple whether it works.
    _ = run(gpa, options.root, &.{
        "xcrun", "notarytool", "history", "--keychain-profile", options.profile,
    }, "the notary profile");
}

fn join(gpa: std.mem.Allocator, parts: []const []const u8) []u8 {
    return std.fs.path.join(gpa, parts) catch @panic("OOM");
}

fn print(gpa: std.mem.Allocator, comptime format: []const u8, args: anytype) []u8 {
    return std.fmt.allocPrint(gpa, format, args) catch @panic("OOM");
}

fn fail_at(what: []const u8, path: []const u8, err: anyerror) noreturn {
    fail("cannot {s} {s}: {s}", .{ what, path, @errorName(err) });
}

fn package(gpa: std.mem.Allocator, options: Options) void {
    const out = std.fs.path.resolve(gpa, &.{ options.root, options.out }) catch @panic("OOM");
    std.fs.cwd().deleteTree(out) catch |err| fail_at("empty", out, err);
    var stem_buffer: [96]u8 = undefined;
    const stem = archive_stem(&stem_buffer, options.version);
    const stage = join(gpa, &.{ out, stem });
    std.fs.cwd().makePath(stage) catch |err| fail_at("make", stage, err);
    const binary = join(gpa, &.{ stage, "nerva" });

    const lipo_args = [_][]const u8{
        "lipo", "-create", "-output", binary, options.arm64, options.x86_64,
    };
    _ = run(gpa, out, &lipo_args, "lipo");
    const archs = run(gpa, out, &.{ "lipo", "-archs", binary }, "lipo");
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
    _ = run(gpa, out, &.{ "ditto", "-c", "-k", "--keepParent", stage, zip }, "ditto");
    check_unzipped(gpa, out, zip, binary);
    const sha = write_checksum(gpa, zip, zip_name);

    if (options.notarize) {
        const submitted = run(gpa, out, &.{
            "xcrun", "notarytool", "submit", zip, "--keychain-profile", options.profile, "--wait",
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
    var argv_buffer: [9][]const u8 = undefined;
    _ = run(gpa, cwd, codesign_args(&argv_buffer, options.identity, binary), "codesign");
    _ = run(gpa, cwd, &.{ "codesign", "--verify", "--strict", binary }, "codesign --verify");
    const shown = run(gpa, cwd, &.{ "codesign", "-dvvv", binary }, "codesign -dv");
    // `codesign -d` writes to stderr.
    const adhoc = std.mem.eql(u8, options.identity, "-");
    if (check_signature(shown.stderr, adhoc)) |refusal| refuse(refusal);
}

/// The signed binary runs, and the hardened runtime does not break `format`.
fn run_signed(gpa: std.mem.Allocator, options: Options, binary: []const u8) void {
    const commit = run(gpa, options.root, &.{ "git", "rev-parse", "--short=7", "HEAD" }, "git");
    const short = std.mem.trim(u8, commit.stdout, " \r\n");
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
    _ = run(gpa, out, &.{ "ditto", "-x", "-k", zip, unzipped_dir }, "ditto");
    const name = std.fs.path.basename(zip);
    const copy = join(gpa, &.{ unzipped_dir, name[0 .. name.len - ".zip".len], "nerva" });
    const signed = run(gpa, out, &.{ "codesign", "-dvvv", binary }, "codesign -dv");
    const unzipped = run(gpa, out, &.{ "codesign", "-dvvv", copy }, "codesign -dv");
    if (check_cdhash(signed.stderr, unzipped.stderr)) |refusal| refuse(refusal);
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
    const template_path = join(gpa, &.{ options.root, options.template });
    const template = std.fs.cwd().readFileAlloc(gpa, template_path, 1 << 20) catch |err|
        fail_at("read", template_path, err);
    const url = print(gpa, "{s}/v{s}/{s}.zip", .{ release_url, options.version, stem });
    const filled = formula_fill(gpa, template, options.version, url, sha) catch |err|
        fail("cannot fill the formula: {s}", .{@errorName(err)});
    const path = join(gpa, &.{ out, "nerva.rb" });
    std.fs.cwd().writeFile(.{ .sub_path = path, .data = filled }) catch |err|
        fail_at("write", path, err);
}

test "archive and tag names" {
    var buffer: [96]u8 = undefined;
    try std.testing.expectEqualStrings(
        "nerva-v0.7.1-universal-macos",
        archive_stem(&buffer, "0.7.1"),
    );
    try std.testing.expectEqualStrings("v0.7.1", tag_name(&buffer, "0.7.1"));
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
    var buffer: [9][]const u8 = undefined;
    const identity = codesign_args(&buffer, default_identity, "/x/nerva");
    try std.testing.expectEqualSlices([]const u8, &.{
        "codesign",    "--force", "--options",      "runtime",
        "--timestamp", "--sign",  default_identity, "/x/nerva",
    }, identity);
    const adhoc = codesign_args(&buffer, "-", "/x/nerva");
    try std.testing.expectEqualSlices([]const u8, &.{
        "codesign",         "--force", "--options", "runtime",
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
}
