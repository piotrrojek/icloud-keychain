const std = @import("std");
const keychain = @import("keychain.zig");
const c = @cImport({
    @cInclude("CoreFoundation/CoreFoundation.h");
    @cInclude("Security/SecBase.h");
    @cInclude("Security/SecCode.h");
    @cInclude("Security/AuthSession.h");
});

fn release(value: anytype) void {
    const ref: c.CFTypeRef = @ptrCast(value);
    if (ref != null) c.CFRelease(ref);
}

fn isType(value: c.CFTypeRef, id: c.CFTypeID) bool {
    return value != null and c.CFGetTypeID(value) == id;
}

fn string(bytes: []const u8) !c.CFStringRef {
    return c.CFStringCreateWithBytes(null, bytes.ptr, @intCast(bytes.len), c.kCFStringEncodingUTF8, 0) orelse error.OutOfMemory;
}

fn field(dict: c.CFTypeRef, name: []const u8) !c.CFTypeRef {
    if (!isType(dict, c.CFDictionaryGetTypeID())) return null;
    const key = try string(name);
    defer release(key);
    return c.CFDictionaryGetValue(@ptrCast(dict), key);
}

fn equals(value: c.CFTypeRef, bytes: []const u8) !bool {
    if (!isType(value, c.CFStringGetTypeID())) return false;
    const expected = try string(bytes);
    defer release(expected);
    return c.CFEqual(value, expected) != 0;
}

fn grants(value: c.CFTypeRef, identifier: []const u8) !bool {
    if (try equals(value, identifier)) return true;
    // Provisioning profiles may authorize a team-prefixed wildcard.
    const dot = std.mem.indexOfScalar(u8, identifier, '.') orelse return false;
    var buf: [128]u8 = undefined;
    const wildcard = std.fmt.bufPrint(&buf, "{s}.*", .{identifier[0..dot]}) catch return false;
    return equals(value, wildcard);
}

fn containsGroup(value: c.CFTypeRef, allow_wildcard: bool) !bool {
    if (!isType(value, c.CFArrayGetTypeID())) return false;
    const array: c.CFArrayRef = @ptrCast(value);
    const count: usize = @intCast(c.CFArrayGetCount(array));
    for (0..count) |i| {
        const group = c.CFArrayGetValueAtIndex(array, @intCast(i));
        if (if (allow_wildcard) try grants(group, keychain.access_group) else try equals(group, keychain.access_group)) return true;
    }
    return false;
}

const Profile = struct {
    decoded: bool = false,
    unexpired: bool = false,
    permits_group: bool = false,
    permits_app: bool = false,

    fn ready(self: Profile) bool {
        return self.decoded and self.unexpired and self.permits_group and self.permits_app;
    }
};

fn inspectProfile(xml: []const u8, now: c.CFAbsoluteTime) !Profile {
    const data = c.CFDataCreate(null, xml.ptr, @intCast(xml.len)) orelse return error.OutOfMemory;
    defer release(data);
    var failure: c.CFErrorRef = null;
    defer release(failure);
    const plist = c.CFPropertyListCreateWithData(null, data, c.kCFPropertyListImmutable, null, &failure);
    defer release(plist);
    if (!isType(plist, c.CFDictionaryGetTypeID())) return .{};
    const expiration = try field(plist, "ExpirationDate");
    const entitlements = try field(plist, "Entitlements");
    const app = (try field(entitlements, "com.apple.application-identifier")) orelse try field(entitlements, "application-identifier");
    return .{
        .decoded = true,
        .unexpired = isType(expiration, c.CFDateGetTypeID()) and c.CFDateGetAbsoluteTime(@ptrCast(expiration)) > now,
        .permits_group = try containsGroup(try field(entitlements, "keychain-access-groups"), true),
        .permits_app = try grants(app, keychain.access_group),
    };
}

fn profilePath(allocator: std.mem.Allocator, executable: []const u8) !?[]u8 {
    const macos = std.fs.path.dirname(executable) orelse return null;
    if (!std.mem.eql(u8, std.fs.path.basename(macos), "MacOS")) return null;
    const contents = std.fs.path.dirname(macos) orelse return null;
    if (!std.mem.eql(u8, std.fs.path.basename(contents), "Contents")) return null;
    const bundle = std.fs.path.dirname(contents) orelse return null;
    if (!std.mem.endsWith(u8, bundle, ".app")) return null;
    return try std.fs.path.join(allocator, &.{ contents, "embedded.provisionprofile" });
}

fn yesNo(value: bool) []const u8 {
    return if (value) "yes" else "no";
}

pub fn run(allocator: std.mem.Allocator, out: *std.Io.Writer) !bool {
    const executable = try std.fs.selfExePathAlloc(allocator);
    defer allocator.free(executable);
    const resolved = try std.fs.cwd().realpathAlloc(allocator, executable);
    defer allocator.free(resolved);
    try out.print("Executable: {s}\n", .{resolved});
    try out.writeAll("Local scope: default file keychain (normally login); no sync entitlement required.\n");

    var code: c.SecCodeRef = null;
    defer release(code);
    var info: c.CFDictionaryRef = null;
    defer release(info);
    var valid_signature = false;
    var signed_group = false;
    var signed_app = false;
    var status = c.SecCodeCopySelf(c.kSecCSDefaultFlags, &code);
    if (status == c.errSecSuccess and code != null) {
        status = c.SecCodeCheckValidity(code, c.kSecCSDefaultFlags, null);
        valid_signature = status == c.errSecSuccess;
        if (c.SecCodeCopySigningInformation(@ptrCast(code), c.kSecCSSigningInformation, &info) == c.errSecSuccess and info != null) {
            const entitlements = c.CFDictionaryGetValue(info, @ptrCast(c.kSecCodeInfoEntitlementsDict));
            signed_group = try containsGroup(try field(entitlements, "keychain-access-groups"), false);
            signed_app = try equals(try field(entitlements, "com.apple.application-identifier"), keychain.access_group);
        }
    }
    try out.print("Valid running code signature: {s} (OSStatus {d})\n", .{ yesNo(valid_signature), status });
    try out.print("Signed application identifier matches: {s}\nSigned access group matches: {s}\n", .{ yesNo(signed_app), yesNo(signed_group) });

    var profile: Profile = .{};
    if (try profilePath(allocator, resolved)) |path| {
        defer allocator.free(path);
        const decoded = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "/usr/bin/security", "cms", "-D", "-i", path },
            .max_output_bytes = 4 * 1024 * 1024,
        }) catch null;
        if (decoded) |result| {
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            if (result.term == .Exited and result.term.Exited == 0) profile = try inspectProfile(result.stdout, c.CFAbsoluteTimeGetCurrent());
        }
    }
    try out.print("Embedded profile decoded: {s}\nProfile unexpired: {s}\nProfile permits application/access group: {s}\n", .{
        yesNo(profile.decoded), yesNo(profile.unexpired), yesNo(profile.permits_group and profile.permits_app),
    });

    var session: c.SecuritySessionId = 0;
    var attributes: c.SessionAttributeBits = 0;
    const session_status = c.SessionGetInfo(c.callerSecuritySession, &session, &attributes);
    const graphical = session_status == c.errSecSuccess and attributes & c.sessionHasGraphicAccess != 0;
    try out.print("Security session has graphical access: {s} (OSStatus {d})\n", .{ yesNo(graphical), session_status });
    try out.writeAll("iCloud requires an authorized signed .app/profile and the user's login session.\n" ++
        "These are local diagnostics, not proof of profile authorization, account health, or remote sync.\n" ++
        "No keychain items were read or written. For an unsigned local build use --local.\n");
    return valid_signature and signed_app and signed_group and profile.ready() and graphical;
}

const profile_fixture =
    "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict>" ++
    "<key>ExpirationDate</key><date>2099-01-01T00:00:00Z</date>" ++
    "<key>Entitlements</key><dict>" ++
    "<key>com.apple.application-identifier</key><string>RE4JN752MW.*</string>" ++
    "<key>keychain-access-groups</key><array><string>RE4JN752MW.*</string></array>" ++
    "</dict></dict></plist>";

test "doctor profile checks expiry, group and application without secret reads" {
    const valid = try inspectProfile(profile_fixture, 0);
    try std.testing.expect(valid.ready());
    const expired = try inspectProfile(profile_fixture, 4_000_000_000);
    try std.testing.expect(!expired.ready());
    const missing = try inspectProfile("<plist><dict/></plist>", 0);
    try std.testing.expect(!missing.ready());
    const invalid = try inspectProfile("not a plist", 0);
    try std.testing.expect(!invalid.ready());
    const wrong = try string("WRONGTEAM.*");
    defer release(wrong);
    try std.testing.expect(!try grants(wrong, keychain.access_group));
}

test "doctor locates profile only in app bundle layout" {
    const path = (try profilePath(std.testing.allocator, "/opt/test.app/Contents/MacOS/icloud-keychain")).?;
    defer std.testing.allocator.free(path);
    try std.testing.expectEqualStrings("/opt/test.app/Contents/embedded.provisionprofile", path);
    try std.testing.expectEqual(@as(?[]u8, null), try profilePath(std.testing.allocator, "/opt/bin/icloud-keychain"));
}
