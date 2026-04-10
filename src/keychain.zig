// icloud-keychain — macOS Keychain CLI with iCloud sync, written in Zig.
// Copyright (c) 2026 Piotr Rojek — https://piotrrojek.io
// MIT License
//
// keychain.zig — Zig bindings for the macOS Security framework's Keychain Services.

const std = @import("std");

// linked in build.zig
const c = @cImport({
    @cInclude("CoreFoundation/CoreFoundation.h");
    @cInclude("Security/Security.h");
});

pub const KeychainError = error{
    ItemNotFound,
    DuplicateItem,
    AuthFailed,
    MissingEntitlement,
    Unexpected,
    CFAllocFailed,
};

fn mapStatus(status: c.OSStatus) KeychainError!void {
    return switch (status) {
        c.errSecSuccess => {},
        c.errSecItemNotFound => KeychainError.ItemNotFound,
        c.errSecDuplicateItem => KeychainError.DuplicateItem,
        c.errSecAuthFailed => KeychainError.AuthFailed,
        -34018 => KeychainError.MissingEntitlement,
        else => {
            std.debug.print("Keychain OSStatus: {d}\n", .{status});
            return KeychainError.Unexpected;
        },
    };
}

/// Create a CFStringRef from a Zig string slice.
fn cfStr(bytes: []const u8) KeychainError!c.CFStringRef {
    return c.CFStringCreateWithBytes(
        null, // kCFAllocatorDefault
        bytes.ptr,
        @intCast(bytes.len),
        c.kCFStringEncodingUTF8,
        0, // isExternalRepresentation = false
    ) orelse return KeychainError.CFAllocFailed;
}

fn cfData(bytes: []const u8) KeychainError!c.CFDataRef {
    return c.CFDataCreate(
        null,
        bytes.ptr,
        @intCast(bytes.len),
    ) orelse return KeychainError.CFAllocFailed;
}

/// Shorthand for CFDictionarySetValue with the required @ptrCast.
fn dictSet(dict: c.CFMutableDictionaryRef, key: anytype, value: anytype) void {
    c.CFDictionarySetValue(
        dict,
        @as(?*const anyopaque, @ptrCast(key)),
        @as(?*const anyopaque, @ptrCast(value)),
    );
}

/// Create a new mutable CFDictionary with default callbacks.
fn dictCreate() KeychainError!c.CFMutableDictionaryRef {
    return c.CFDictionaryCreateMutable(
        null,
        0,
        &c.kCFTypeDictionaryKeyCallBacks,
        &c.kCFTypeDictionaryValueCallBacks,
    ) orelse return KeychainError.CFAllocFailed;
}

/// Release a CoreFoundation object. Accepts any CF pointer type.
fn cfRelease(ref: anytype) void {
    c.CFRelease(@as(c.CFTypeRef, @ptrCast(ref)));
}

/// When `sync` is true, sets `kSecAttrSynchronizable = true` to enable
/// iCloud Keychain sync across all devices signed into the same Apple ID.
pub fn set(service: []const u8, account: []const u8, password: []const u8, sync: bool) KeychainError!void {
    // Delete any existing item first (ignore "not found").
    delete(service, account) catch |err| switch (err) {
        KeychainError.ItemNotFound => {},
        else => return err,
    };

    const cf_service = try cfStr(service);
    defer cfRelease(cf_service);
    const cf_account = try cfStr(account);
    defer cfRelease(cf_account);
    const cf_password = try cfData(password);
    defer cfRelease(cf_password);

    const dict = try dictCreate();
    defer cfRelease(dict);

    dictSet(dict, c.kSecClass, c.kSecClassGenericPassword);
    // namespace (e.g. "dotfiles/github-token")
    dictSet(dict, c.kSecAttrService, cf_service);
    dictSet(dict, c.kSecAttrAccount, cf_account);
    dictSet(dict, c.kSecValueData, cf_password);
    // Available after first unlock (survives reboots, but not before login)
    dictSet(dict, c.kSecAttrAccessible, c.kSecAttrAccessibleAfterFirstUnlock);

    if (sync) {
        // Enable iCloud Keychain sync
        dictSet(dict, c.kSecAttrSynchronizable, c.kCFBooleanTrue);
    }

    try mapStatus(c.SecItemAdd(dict, null));
}

pub fn get(allocator: std.mem.Allocator, service: []const u8, account: []const u8) (KeychainError || std.mem.Allocator.Error)![]u8 {
    const cf_service = try cfStr(service);
    defer cfRelease(cf_service);
    const cf_account = try cfStr(account);
    defer cfRelease(cf_account);

    const dict = try dictCreate();
    defer cfRelease(dict);

    dictSet(dict, c.kSecClass, c.kSecClassGenericPassword);
    dictSet(dict, c.kSecAttrService, cf_service);
    dictSet(dict, c.kSecAttrAccount, cf_account);
    // Search across both local and iCloud keychains
    dictSet(dict, c.kSecAttrSynchronizable, c.kSecAttrSynchronizableAny);
    // We want the password bytes back
    dictSet(dict, c.kSecReturnData, c.kCFBooleanTrue);
    // Return only one match
    dictSet(dict, c.kSecMatchLimit, c.kSecMatchLimitOne);

    // SecItemCopyMatching writes a CFTypeRef into `result`.
    // On success it will be a CFDataRef containing the password.
    var result: c.CFTypeRef = null;
    try mapStatus(c.SecItemCopyMatching(dict, &result));
    defer cfRelease(result);

    // Cast to CFDataRef and extract the bytes
    const data: c.CFDataRef = @ptrCast(result);
    const len: usize = @intCast(c.CFDataGetLength(data));
    const ptr = c.CFDataGetBytePtr(data);

    const buf = try allocator.alloc(u8, len);
    @memcpy(buf, ptr[0..len]);
    return buf;
}

pub fn delete(service: []const u8, account: []const u8) KeychainError!void {
    const cf_service = try cfStr(service);
    defer cfRelease(cf_service);
    const cf_account = try cfStr(account);
    defer cfRelease(cf_account);

    const dict = try dictCreate();
    defer cfRelease(dict);

    dictSet(dict, c.kSecClass, c.kSecClassGenericPassword);
    dictSet(dict, c.kSecAttrService, cf_service);
    dictSet(dict, c.kSecAttrAccount, cf_account);
    dictSet(dict, c.kSecAttrSynchronizable, c.kSecAttrSynchronizableAny);

    try mapStatus(c.SecItemDelete(dict));
}

/// List all generic password items, optionally filtered by service prefix.
/// Prints "service / account" lines to stdout.
/// FIX: currently filtering is broken -- needs investigation.
pub fn list(service_filter: ?[]const u8) KeychainError!void {
    const dict = try dictCreate();
    defer cfRelease(dict);

    dictSet(dict, c.kSecClass, c.kSecClassGenericPassword);
    dictSet(dict, c.kSecAttrSynchronizable, c.kSecAttrSynchronizableAny);
    dictSet(dict, c.kSecReturnAttributes, c.kCFBooleanTrue);
    dictSet(dict, c.kSecMatchLimit, c.kSecMatchLimitAll);

    if (service_filter) |filter| {
        const cf_filter = try cfStr(filter);
        defer cfRelease(cf_filter);
        dictSet(dict, c.kSecAttrService, cf_filter);
    }

    var result: c.CFTypeRef = null;
    mapStatus(c.SecItemCopyMatching(dict, &result)) catch |err| switch (err) {
        KeychainError.ItemNotFound => {
            std.fs.File.stdout().writeAll("No items found.\n") catch {};
            return;
        },
        else => return err,
    };
    defer cfRelease(result);

    // result is a CFArrayRef of CFDictionaryRef items
    const array: c.CFArrayRef = @ptrCast(result);
    const count: usize = @intCast(c.CFArrayGetCount(array));
    const out = std.fs.File.stdout();

    for (0..count) |i| {
        const item: c.CFDictionaryRef = @ptrCast(c.CFArrayGetValueAtIndex(array, @intCast(i)));
        printAttribute(out, item, c.kSecAttrService);
        out.writeAll(" / ") catch {};
        printAttribute(out, item, c.kSecAttrAccount);
        out.writeAll("\n") catch {};
    }
}

fn printAttribute(out: std.fs.File, dict: c.CFDictionaryRef, key: anytype) void {
    var value: ?*const anyopaque = null;
    if (c.CFDictionaryGetValueIfPresent(dict, @as(?*const anyopaque, @ptrCast(key)), &value) == 0) {
        out.writeAll("?") catch {};
        return;
    }
    const cf_str: c.CFStringRef = @ptrCast(value);
    var buf: [256]u8 = undefined;
    if (c.CFStringGetCString(cf_str, &buf, buf.len, c.kCFStringEncodingUTF8) != 0) {
        const len = std.mem.indexOfScalar(u8, &buf, 0) orelse buf.len;
        out.writeAll(buf[0..len]) catch {};
    } else {
        out.writeAll("?") catch {};
    }
}
