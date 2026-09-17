// Copyright (c) 2026 Piotr Rojek — https://piotrrojek.io
// MIT License

const std = @import("std");
const types = @import("types.zig");
pub const Scope = types.Scope;
pub const Entry = types.Entry;
pub const freeEntries = types.freeEntries;
pub const access_group = "RE4JN752MW.com.otherlandlabs.icloud-keychain";

const c = @cImport({
    @cInclude("CoreFoundation/CoreFoundation.h");
    @cInclude("Security/SecItem.h");
    @cInclude("Security/SecKeychain.h");
});

pub const KeychainError = error{
    ItemNotFound,
    DuplicateItem,
    AuthFailed,
    MissingEntitlement,
    InteractionNotAllowed,
    UserCanceled,
    KeychainUnavailable,
    InvalidArgument,
    InvalidUtf8,
    InvalidScope,
    InvalidResult,
    AmbiguousItem,
    ConcurrentModification,
    Unexpected,
    CFAllocFailed,
};

fn mapStatus(status: c.OSStatus) KeychainError!void {
    return switch (status) {
        c.errSecSuccess => {},
        c.errSecItemNotFound => error.ItemNotFound,
        c.errSecDuplicateItem => error.DuplicateItem,
        c.errSecAuthFailed => error.AuthFailed,
        c.errSecMissingEntitlement => error.MissingEntitlement,
        c.errSecInteractionNotAllowed => error.InteractionNotAllowed,
        c.errSecUserCanceled => error.UserCanceled,
        c.errSecNotAvailable, c.errSecNoSuchKeychain, c.errSecInvalidKeychain => error.KeychainUnavailable,
        c.errSecParam => error.InvalidArgument,
        else => {
            std.debug.print("Keychain OSStatus: {d}\n", .{status});
            return error.Unexpected;
        },
    };
}

fn cfStr(bytes: []const u8) KeychainError!c.CFStringRef {
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    return c.CFStringCreateWithBytes(null, bytes.ptr, @intCast(bytes.len), c.kCFStringEncodingUTF8, 0) orelse error.CFAllocFailed;
}

const empty_data_sentinel = [_]u8{0};

fn cfData(bytes: []const u8) KeychainError!c.CFDataRef {
    // A null data pointer means "unchanged" to the legacy file-keychain update API.
    if (bytes.len == 0) return c.CFDataCreateWithBytesNoCopy(null, &empty_data_sentinel, 0, c.kCFAllocatorNull) orelse error.CFAllocFailed;
    return c.CFDataCreate(null, bytes.ptr, @intCast(bytes.len)) orelse error.CFAllocFailed;
}

fn dictSet(dict: c.CFMutableDictionaryRef, key: anytype, value: anytype) void {
    c.CFDictionarySetValue(dict, @ptrCast(key), @ptrCast(value));
}

fn dictCreate() KeychainError!c.CFMutableDictionaryRef {
    return c.CFDictionaryCreateMutable(null, 0, &c.kCFTypeDictionaryKeyCallBacks, &c.kCFTypeDictionaryValueCallBacks) orelse error.CFAllocFailed;
}

fn cfRelease(ref: anytype) void {
    const value: c.CFTypeRef = @ptrCast(ref);
    if (value != null) c.CFRelease(value);
}

fn requireType(value: c.CFTypeRef, expected: c.CFTypeID) KeychainError!void {
    if (value == null or c.CFGetTypeID(value) != expected) return error.InvalidResult;
}

fn stringAttribute(allocator: std.mem.Allocator, dict: c.CFDictionaryRef, key: c.CFStringRef) ![]u8 {
    const value = c.CFDictionaryGetValue(dict, @ptrCast(key));
    // Legacy file-keychain items can omit empty service/account attributes.
    if (value == null) return allocator.dupe(u8, "");
    try requireType(value, c.CFStringGetTypeID());
    const str: c.CFStringRef = @ptrCast(value);
    const length = c.CFStringGetLength(str);
    const range = c.CFRange{ .location = 0, .length = length };
    var size: c.CFIndex = 0;
    if (c.CFStringGetBytes(str, range, c.kCFStringEncodingUTF8, 0, 0, null, 0, &size) != length or size < 0) return error.InvalidResult;
    const bytes = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(bytes);
    var written: c.CFIndex = 0;
    if (size != 0 and (c.CFStringGetBytes(str, range, c.kCFStringEncodingUTF8, 0, 0, bytes.ptr, size, &written) != length or written != size)) return error.InvalidResult;
    return bytes;
}

const Native = struct {
    const copyDefault = c.SecKeychainCopyDefault;
    const update = c.SecItemUpdate;
    const add = c.SecItemAdd;
    const copy = c.SecItemCopyMatching;
    const remove = c.SecItemDelete;
};

pub const set = Store(Native).set;
pub const get = Store(Native).get;
pub const delete = Store(Native).delete;
pub const list = Store(Native).list;

fn Store(comptime api: type) type {
    return struct {
        const Query = struct {
            dict: c.CFMutableDictionaryRef,
            local_keychain: c.SecKeychainRef = null,

            fn init(scope: Scope, service: ?[]const u8, account: ?[]const u8) !Query {
                if (scope == .any) return error.InvalidScope;
                var query = Query{ .dict = try dictCreate() };
                errdefer query.deinit();
                dictSet(query.dict, c.kSecClass, c.kSecClassGenericPassword);
                if (service) |s| {
                    const value = try cfStr(s);
                    defer cfRelease(value);
                    dictSet(query.dict, c.kSecAttrService, value);
                }
                if (account) |a| {
                    const value = try cfStr(a);
                    defer cfRelease(value);
                    dictSet(query.dict, c.kSecAttrAccount, value);
                }
                const sync = if (scope == .icloud) c.kCFBooleanTrue else c.kCFBooleanFalse;
                // Explicit DP routing prevents Security.framework from searching both stores.
                dictSet(query.dict, c.kSecUseDataProtectionKeychain, sync);
                dictSet(query.dict, c.kSecAttrSynchronizable, sync);
                if (scope == .local) {
                    try mapStatus(api.copyDefault(&query.local_keychain));
                    if (query.local_keychain == null) return error.InvalidResult;
                    var values = [_]?*const anyopaque{@ptrCast(query.local_keychain)};
                    const search = c.CFArrayCreate(null, &values, 1, &c.kCFTypeArrayCallBacks) orelse return error.CFAllocFailed;
                    defer cfRelease(search);
                    dictSet(query.dict, c.kSecMatchSearchList, search);
                } else {
                    const group = try cfStr(access_group);
                    defer cfRelease(group);
                    dictSet(query.dict, c.kSecAttrAccessGroup, group);
                }
                return query;
            }

            fn deinit(self: Query) void {
                cfRelease(self.dict);
                cfRelease(self.local_keychain);
            }
        };

        pub fn set(service: []const u8, account: []const u8, password: []const u8, scope: Scope) !void {
            const query = try Query.init(scope, service, account);
            defer query.deinit();
            const data = try cfData(password);
            defer cfRelease(data);
            const changes = try dictCreate();
            defer cfRelease(changes);
            dictSet(changes, c.kSecValueData, data);

            const addition = c.CFDictionaryCreateMutableCopy(null, 0, query.dict) orelse return error.CFAllocFailed;
            defer cfRelease(addition);
            dictSet(addition, c.kSecValueData, data);
            if (scope == .local) {
                c.CFDictionaryRemoveValue(addition, @ptrCast(c.kSecMatchSearchList));
                dictSet(addition, c.kSecUseKeychain, query.local_keychain);
            } else {
                dictSet(addition, c.kSecAttrAccessible, c.kSecAttrAccessibleAfterFirstUnlock);
            }

            // Updating only data preserves ACLs and never deletes the previous value.
            mapStatus(api.update(query.dict, changes)) catch |err| switch (err) {
                error.ItemNotFound => {
                    mapStatus(api.add(addition, null)) catch |add_error| switch (add_error) {
                        error.DuplicateItem => {
                            // A competing creator won; retry once, without deletion or migration.
                            mapStatus(api.update(query.dict, changes)) catch |retry_error| {
                                if (retry_error == error.ItemNotFound) return error.ConcurrentModification;
                                return retry_error;
                            };
                        },
                        else => return add_error,
                    };
                },
                else => return err,
            };
        }

        fn matchCount(query: c.CFMutableDictionaryRef) !usize {
            const probe = c.CFDictionaryCreateMutableCopy(null, 0, query) orelse return error.CFAllocFailed;
            defer cfRelease(probe);
            dictSet(probe, c.kSecReturnAttributes, c.kCFBooleanTrue);
            dictSet(probe, c.kSecMatchLimit, c.kSecMatchLimitAll);
            var result: c.CFTypeRef = null;
            defer cfRelease(result);
            mapStatus(api.copy(probe, &result)) catch |err| switch (err) {
                error.ItemNotFound => return 0,
                else => return err,
            };
            try requireType(result, c.CFArrayGetTypeID());
            return @intCast(c.CFArrayGetCount(@ptrCast(result)));
        }

        pub fn get(allocator: std.mem.Allocator, service: []const u8, account: []const u8, scope: Scope) ![]u8 {
            if (scope == .any) {
                const local = try Query.init(.local, service, account);
                defer local.deinit();
                const cloud = try Query.init(.icloud, service, account);
                defer cloud.deinit();
                const local_count = try matchCount(local.dict);
                const cloud_count = try matchCount(cloud.dict);
                if (local_count + cloud_count > 1) return error.AmbiguousItem;
                if (local_count + cloud_count == 0) return error.ItemNotFound;
                return readData(allocator, if (local_count == 1) local.dict else cloud.dict);
            }
            const query = try Query.init(scope, service, account);
            defer query.deinit();
            const count = try matchCount(query.dict);
            if (count > 1) return error.AmbiguousItem;
            if (count == 0) return error.ItemNotFound;
            return readData(allocator, query.dict);
        }

        fn readData(allocator: std.mem.Allocator, query: c.CFMutableDictionaryRef) ![]u8 {
            dictSet(query, c.kSecReturnData, c.kCFBooleanTrue);
            dictSet(query, c.kSecMatchLimit, c.kSecMatchLimitOne);
            var result: c.CFTypeRef = null;
            defer cfRelease(result);
            try mapStatus(api.copy(query, &result));
            try requireType(result, c.CFDataGetTypeID());
            const data: c.CFDataRef = @ptrCast(result);
            const length = c.CFDataGetLength(data);
            if (length < 0) return error.InvalidResult;
            const bytes = try allocator.alloc(u8, @intCast(length));
            errdefer allocator.free(bytes);
            if (bytes.len != 0) {
                const ptr = c.CFDataGetBytePtr(data);
                if (ptr == null) return error.InvalidResult;
                @memcpy(bytes, ptr[0..bytes.len]);
            }
            return bytes;
        }

        pub fn delete(service: []const u8, account: []const u8, scope: Scope) !void {
            const query = try Query.init(scope, service, account);
            defer query.deinit();
            const count = try matchCount(query.dict);
            if (count > 1) return error.AmbiguousItem;
            if (count == 0) return error.ItemNotFound;
            try mapStatus(api.remove(query.dict));
        }

        pub fn list(allocator: std.mem.Allocator, prefix: ?[]const u8, scope: Scope) ![]Entry {
            var entries: std.ArrayList(Entry) = .empty;
            errdefer {
                for (entries.items) |entry| entry.deinit(allocator);
                entries.deinit(allocator);
            }
            if (scope != .icloud) try appendList(allocator, &entries, prefix, .local);
            if (scope != .local) try appendList(allocator, &entries, prefix, .icloud);
            return entries.toOwnedSlice(allocator);
        }

        fn appendList(allocator: std.mem.Allocator, entries: *std.ArrayList(Entry), prefix: ?[]const u8, scope: Scope) !void {
            const query = try Query.init(scope, null, null);
            defer query.deinit();
            dictSet(query.dict, c.kSecReturnAttributes, c.kCFBooleanTrue);
            dictSet(query.dict, c.kSecMatchLimit, c.kSecMatchLimitAll);
            var result: c.CFTypeRef = null;
            defer cfRelease(result);
            mapStatus(api.copy(query.dict, &result)) catch |err| switch (err) {
                error.ItemNotFound => return,
                else => return err,
            };
            try requireType(result, c.CFArrayGetTypeID());
            const array: c.CFArrayRef = @ptrCast(result);
            const count: usize = @intCast(c.CFArrayGetCount(array));
            for (0..count) |i| {
                const raw_item = c.CFArrayGetValueAtIndex(array, @intCast(i));
                try requireType(raw_item, c.CFDictionaryGetTypeID());
                const item: c.CFDictionaryRef = @ptrCast(raw_item);
                const service = try stringAttribute(allocator, item, c.kSecAttrService);
                errdefer allocator.free(service);
                if (prefix) |filter| {
                    if (!std.mem.startsWith(u8, service, filter)) {
                        allocator.free(service);
                        continue;
                    }
                }
                const account = try stringAttribute(allocator, item, c.kSecAttrAccount);
                errdefer allocator.free(account);
                try entries.append(allocator, .{ .service = service, .account = account, .scope = scope });
            }
        }
    };
}

const Mock = struct {
    var updates: [2]c.OSStatus = .{ 0, 0 };
    var addition: c.OSStatus = 0;
    var copy_status: c.OSStatus = 0;
    var cloud_status: c.OSStatus = 0;
    var update_count: usize = 0;
    var add_count: usize = 0;
    var delete_count: usize = 0;
    var data_reads: usize = 0;
    var local_count: usize = 1;
    var cloud_count: usize = 0;
    var expected_scope: Scope = .local;
    var secret: []const u8 = "old dummy value";
    var stored: []const u8 = "old dummy value";
    var malformed: bool = false;
    var omit_first_attributes: bool = false;

    fn reset(scope: Scope) void {
        updates = .{ 0, 0 };
        addition = 0;
        copy_status = 0;
        cloud_status = 0;
        update_count = 0;
        add_count = 0;
        delete_count = 0;
        data_reads = 0;
        local_count = 1;
        cloud_count = 0;
        expected_scope = scope;
        secret = "old dummy value";
        stored = "old dummy value";
        malformed = false;
        omit_first_attributes = false;
    }

    fn copyDefault(result: [*c]c.SecKeychainRef) c.OSStatus {
        result.* = @ptrCast(@constCast(cfStr("test-keychain-only") catch unreachable));
        return 0;
    }

    fn attr(dict: c.CFDictionaryRef, key: c.CFStringRef) c.CFTypeRef {
        return c.CFDictionaryGetValue(dict, @ptrCast(key));
    }

    fn has(dict: c.CFDictionaryRef, key: c.CFStringRef, value: anytype) bool {
        return attr(dict, key) == @as(c.CFTypeRef, @ptrCast(value));
    }

    fn assertScope(dict: c.CFDictionaryRef, adding: bool) void {
        const sync = if (expected_scope == .icloud) c.kCFBooleanTrue else c.kCFBooleanFalse;
        std.debug.assert(has(dict, c.kSecUseDataProtectionKeychain, sync));
        std.debug.assert(has(dict, c.kSecAttrSynchronizable, sync));
        if (expected_scope == .local) {
            const key = if (adding) c.kSecUseKeychain else c.kSecMatchSearchList;
            std.debug.assert(attr(dict, key) != null);
            std.debug.assert(attr(dict, if (adding) c.kSecMatchSearchList else c.kSecUseKeychain) == null);
            std.debug.assert(attr(dict, c.kSecAttrAccessGroup) == null);
            std.debug.assert(attr(dict, c.kSecAttrAccessible) == null);
        } else {
            std.debug.assert(attr(dict, c.kSecMatchSearchList) == null);
            std.debug.assert(attr(dict, c.kSecUseKeychain) == null);
            const group = cfStr(access_group) catch unreachable;
            defer cfRelease(group);
            std.debug.assert(c.CFEqual(attr(dict, c.kSecAttrAccessGroup), group) != 0);
            if (adding) std.debug.assert(has(dict, c.kSecAttrAccessible, c.kSecAttrAccessibleAfterFirstUnlock));
        }
    }

    fn update(query: c.CFDictionaryRef, changes: c.CFDictionaryRef) c.OSStatus {
        assertScope(query, false);
        std.debug.assert(attr(query, c.kSecAttrService) != null);
        std.debug.assert(attr(query, c.kSecAttrAccount) != null);
        std.debug.assert(c.CFDictionaryGetCount(changes) == 1);
        std.debug.assert(attr(changes, c.kSecValueData) != null);
        std.debug.assert(update_count < updates.len);
        const status = updates[update_count];
        update_count += 1;
        if (status == 0) stored = "new dummy value";
        return status;
    }

    fn add(query: c.CFDictionaryRef, _: ?*c.CFTypeRef) c.OSStatus {
        assertScope(query, true);
        add_count += 1;
        if (addition == 0) stored = "new dummy value";
        return addition;
    }

    fn remove(query: c.CFDictionaryRef) c.OSStatus {
        assertScope(query, false);
        std.debug.assert(attr(query, c.kSecAttrService) != null);
        std.debug.assert(attr(query, c.kSecAttrAccount) != null);
        delete_count += 1;
        return 0;
    }

    fn copy(query: c.CFDictionaryRef, result: *c.CFTypeRef) c.OSStatus {
        const scope: Scope = if (has(query, c.kSecUseDataProtectionKeychain, c.kCFBooleanTrue)) .icloud else .local;
        expected_scope = scope;
        assertScope(query, false);
        if (copy_status != 0) return copy_status;
        if (scope == .icloud and cloud_status != 0) return cloud_status;
        if (malformed) {
            result.* = cfStr("not the requested type") catch unreachable;
            return 0;
        }
        if (has(query, c.kSecReturnData, c.kCFBooleanTrue)) {
            std.debug.assert(has(query, c.kSecMatchLimit, c.kSecMatchLimitOne));
            std.debug.assert(attr(query, c.kSecReturnAttributes) == null);
            data_reads += 1;
            result.* = cfData(secret) catch unreachable;
            return 0;
        }
        std.debug.assert(has(query, c.kSecReturnAttributes, c.kCFBooleanTrue));
        std.debug.assert(has(query, c.kSecMatchLimit, c.kSecMatchLimitAll));
        const count = if (scope == .local) local_count else cloud_count;
        if (count == 0) return c.errSecItemNotFound;
        const array = c.CFArrayCreateMutable(null, 0, &c.kCFTypeArrayCallBacks) orelse unreachable;
        for (0..count) |i| {
            const dict = dictCreate() catch unreachable;
            defer cfRelease(dict);
            if (omit_first_attributes and i == 0) {
                c.CFArrayAppendValue(array, dict);
                continue;
            }
            const service = cfStr("long/" ++ "ę" ** 300 ++ "\x00/with / delimiter") catch unreachable;
            defer cfRelease(service);
            const account = cfStr("account\nwith / separator") catch unreachable;
            defer cfRelease(account);
            dictSet(dict, c.kSecAttrService, service);
            dictSet(dict, c.kSecAttrAccount, account);
            c.CFArrayAppendValue(array, dict);
        }
        result.* = array;
        return 0;
    }
};

test "set updates data only, preserves old value on failure, never deletes" {
    for ([_]Scope{ .local, .icloud }) |scope| {
        Mock.reset(scope);
        try Store(Mock).set("service", "account", "new dummy value", scope);
        try std.testing.expectEqual(@as(usize, 1), Mock.update_count);
        try std.testing.expectEqual(@as(usize, 0), Mock.add_count);
        try std.testing.expectEqual(@as(usize, 0), Mock.delete_count);
        Mock.reset(scope);
        Mock.updates[0] = c.errSecAuthFailed;
        try std.testing.expectError(error.AuthFailed, Store(Mock).set("service", "account", "new", scope));
        try std.testing.expectEqualStrings("old dummy value", Mock.stored);
        try std.testing.expectEqual(@as(usize, 0), Mock.add_count);
        try std.testing.expectEqual(@as(usize, 0), Mock.delete_count);
    }
}

test "set adds only after not-found, and add failure is non-destructive" {
    for ([_]Scope{ .local, .icloud }) |scope| {
        Mock.reset(scope);
        Mock.updates[0] = c.errSecItemNotFound;
        try Store(Mock).set("service", "account", "new", scope);
        try std.testing.expectEqual(@as(usize, 1), Mock.add_count);
        Mock.reset(scope);
        Mock.updates[0] = c.errSecItemNotFound;
        Mock.addition = c.errSecMissingEntitlement;
        try std.testing.expectError(error.MissingEntitlement, Store(Mock).set("service", "account", "new", scope));
        try std.testing.expectEqualStrings("old dummy value", Mock.stored);
        try std.testing.expectEqual(@as(usize, 0), Mock.delete_count);
    }
}

test "duplicate creator race retries update once without deletion" {
    Mock.reset(.local);
    Mock.updates[0] = c.errSecItemNotFound;
    Mock.addition = c.errSecDuplicateItem;
    try Store(Mock).set("service", "account", "new", .local);
    try std.testing.expectEqual(@as(usize, 2), Mock.update_count);
    try std.testing.expectEqual(@as(usize, 0), Mock.delete_count);
    Mock.reset(.icloud);
    Mock.updates = .{ c.errSecItemNotFound, c.errSecItemNotFound };
    Mock.addition = c.errSecDuplicateItem;
    try std.testing.expectError(error.ConcurrentModification, Store(Mock).set("service", "account", "new", .icloud));
    try std.testing.expectEqual(@as(usize, 2), Mock.update_count);
    try std.testing.expectEqual(@as(usize, 0), Mock.delete_count);
}

test "invalid scope and invalid UTF8 fail before mutation" {
    Mock.reset(.local);
    try std.testing.expectError(error.InvalidScope, Store(Mock).set("s", "a", "p", .any));
    try std.testing.expectError(error.InvalidScope, Store(Mock).delete("s", "a", .any));
    try std.testing.expectError(error.InvalidUtf8, Store(Mock).set("\xff", "a", "p", .local));
    try std.testing.expectEqual(@as(usize, 0), Mock.update_count);
    try std.testing.expectEqual(@as(usize, 0), Mock.delete_count);
}

test "ambiguous reads fail before requesting any secret bytes" {
    Mock.reset(.local);
    Mock.cloud_count = 1;
    try std.testing.expectError(error.AmbiguousItem, Store(Mock).get(std.testing.allocator, "s", "a", .any));
    try std.testing.expectEqual(@as(usize, 0), Mock.data_reads);
    Mock.local_count = 2;
    try std.testing.expectError(error.AmbiguousItem, Store(Mock).get(std.testing.allocator, "s", "a", .local));
    try std.testing.expectError(error.AmbiguousItem, Store(Mock).delete("s", "a", .local));
    try std.testing.expectEqual(@as(usize, 0), Mock.delete_count);
}

test "get handles empty, binary, and newline-containing data" {
    for ([_][]const u8{ "", "a\x00\xff\n\r\n" }) |secret| {
        Mock.reset(.local);
        Mock.secret = secret;
        const data = try Store(Mock).get(std.testing.allocator, "s", "a", .any);
        defer std.testing.allocator.free(data);
        try std.testing.expectEqualSlices(u8, secret, data);
        try std.testing.expectEqual(@as(usize, 1), Mock.data_reads);
    }
}

test "empty update data retains a non-null pointer with zero length" {
    const data = try cfData("");
    defer cfRelease(data);
    try std.testing.expectEqual(@as(c.CFIndex, 0), c.CFDataGetLength(data));
    try std.testing.expect(c.CFDataGetBytePtr(data) != null);
}

test "list dynamically decodes long UTF8 and embedded NUL without secrets" {
    Mock.reset(.local);
    const entries = try Store(Mock).list(std.testing.allocator, "long/", .any);
    defer freeEntries(std.testing.allocator, entries);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("long/" ++ "ę" ** 300 ++ "\x00/with / delimiter", entries[0].service);
    try std.testing.expectEqualStrings("account\nwith / separator", entries[0].account);
    try std.testing.expectEqual(@as(usize, 0), Mock.data_reads);
    const empty = try Store(Mock).list(std.testing.allocator, "unmatched", .local);
    defer freeEntries(std.testing.allocator, empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "all list allocation failure paths release owned metadata" {
    const Check = struct {
        fn run(allocator: std.mem.Allocator) !void {
            Mock.reset(.local);
            const entries = try Store(Mock).list(allocator, null, .any);
            defer freeEntries(allocator, entries);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Check.run, .{});
}

test "list tolerates omitted legacy attributes without losing filtered matches" {
    Mock.reset(.local);
    Mock.local_count = 2;
    Mock.omit_first_attributes = true;
    const entries = try Store(Mock).list(std.testing.allocator, null, .local);
    defer freeEntries(std.testing.allocator, entries);
    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("", entries[0].service);
    try std.testing.expectEqualStrings("", entries[0].account);
    const filtered = try Store(Mock).list(std.testing.allocator, "long/", .local);
    defer freeEntries(std.testing.allocator, filtered);
    try std.testing.expectEqual(@as(usize, 1), filtered.len);
    try std.testing.expect(std.mem.startsWith(u8, filtered[0].service, "long/"));
    try std.testing.expectEqual(@as(usize, 0), Mock.data_reads);
}

test "present non-string metadata is still rejected" {
    const dict = try dictCreate();
    defer cfRelease(dict);
    const data = try cfData("not a string");
    defer cfRelease(data);
    dictSet(dict, c.kSecAttrService, data);
    try std.testing.expectError(error.InvalidResult, stringAttribute(std.testing.allocator, dict, c.kSecAttrService));
}

test "not-found, entitlement, interaction, and malformed results propagate" {
    Mock.reset(.local);
    Mock.local_count = 0;
    try std.testing.expectError(error.ItemNotFound, Store(Mock).get(std.testing.allocator, "s", "a", .any));
    Mock.copy_status = c.errSecMissingEntitlement;
    try std.testing.expectError(error.MissingEntitlement, Store(Mock).list(std.testing.allocator, null, .icloud));
    Mock.copy_status = c.errSecInteractionNotAllowed;
    try std.testing.expectError(error.InteractionNotAllowed, Store(Mock).get(std.testing.allocator, "s", "a", .local));
    Mock.copy_status = 0;
    Mock.malformed = true;
    try std.testing.expectError(error.InvalidResult, Store(Mock).list(std.testing.allocator, null, .local));
    try std.testing.expectError(error.InvalidResult, Store(Mock).get(std.testing.allocator, "s", "a", .local));
}

test "any scope never hides a failed iCloud query behind a local match" {
    Mock.reset(.local);
    Mock.cloud_status = c.errSecMissingEntitlement;
    try std.testing.expectError(error.MissingEntitlement, Store(Mock).get(std.testing.allocator, "s", "a", .any));
    try std.testing.expectEqual(@as(usize, 0), Mock.data_reads);
    try std.testing.expectError(error.MissingEntitlement, Store(Mock).list(std.testing.allocator, null, .any));
}

test "any scope reads the only iCloud match and delete stays within each scope" {
    Mock.reset(.icloud);
    Mock.local_count = 0;
    Mock.cloud_count = 1;
    const data = try Store(Mock).get(std.testing.allocator, "s", "a", .any);
    defer std.testing.allocator.free(data);
    try std.testing.expectEqual(Scope.icloud, Mock.expected_scope);
    for ([_]Scope{ .local, .icloud }) |scope| {
        Mock.reset(scope);
        Mock.cloud_count = 1;
        try Store(Mock).delete("s", "a", scope);
        try std.testing.expectEqual(scope, Mock.expected_scope);
        try std.testing.expectEqual(@as(usize, 1), Mock.delete_count);
        try std.testing.expectEqual(@as(usize, 0), Mock.data_reads);
    }
}
