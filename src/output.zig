const std = @import("std");
const types = @import("types.zig");

pub const Error = std.Io.Writer.Error || error{UnsafeDelimiter};

pub fn sortEntries(entries: []types.Entry) void {
    std.mem.sort(types.Entry, entries, {}, struct {
        fn lessThan(_: void, a: types.Entry, b: types.Entry) bool {
            return orderEntry(a, b);
        }
    }.lessThan);
}

fn orderEntry(a: types.Entry, b: types.Entry) bool {
    const service = std.mem.order(u8, a.service, b.service);
    if (service != .eq) return service == .lt;
    const account = std.mem.order(u8, a.account, b.account);
    if (account != .eq) return account == .lt;
    return @intFromEnum(a.scope) < @intFromEnum(b.scope);
}

fn sortAccounts(entries: []types.Entry) void {
    std.mem.sort(types.Entry, entries, {}, struct {
        fn lessThan(_: void, a: types.Entry, b: types.Entry) bool {
            const account = std.mem.order(u8, a.account, b.account);
            if (account != .eq) return account == .lt;
            const service = std.mem.order(u8, a.service, b.service);
            if (service != .eq) return service == .lt;
            return @intFromEnum(a.scope) < @intFromEnum(b.scope);
        }
    }.lessThan);
}

fn isUnsafeRecord(value: []const u8, null_terminated: bool) bool {
    if (null_terminated) return std.mem.indexOfScalar(u8, value, 0) != null;
    return std.mem.indexOfScalar(u8, value, '\n') != null or std.mem.indexOfScalar(u8, value, '\r') != null;
}

const Field = enum { service, account };

fn fieldValue(entry: types.Entry, field: Field) []const u8 {
    return switch (field) {
        .service => entry.service,
        .account => entry.account,
    };
}

pub fn writeHuman(writer: *std.Io.Writer, entries: []types.Entry) std.Io.Writer.Error!void {
    sortEntries(entries);
    if (entries.len == 0) {
        try writer.writeAll("No items found.\n");
        return;
    }
    for (entries) |entry| {
        try writer.print("{s} / {s}\n", .{ entry.service, entry.account });
    }
}

pub fn writeJson(writer: *std.Io.Writer, entries: []types.Entry) std.Io.Writer.Error!void {
    sortEntries(entries);
    var stringify: std.json.Stringify = .{ .writer = writer, .options = .{} };
    try stringify.write(entries);
    try writer.writeByte('\n');
}

pub fn writeNames(
    writer: *std.Io.Writer,
    entries: []types.Entry,
    null_terminated: bool,
) Error!void {
    sortEntries(entries);
    try writeUniqueRecords(writer, entries, .service, null, null_terminated);
}

pub fn writeAccounts(
    writer: *std.Io.Writer,
    entries: []types.Entry,
    exact_service: ?[]const u8,
    null_terminated: bool,
) Error!void {
    if (exact_service != null) {
        sortEntries(entries);
    } else {
        sortAccounts(entries);
    }
    try writeUniqueRecords(writer, entries, .account, exact_service, null_terminated);
}

fn writeUniqueRecords(
    writer: *std.Io.Writer,
    entries: []const types.Entry,
    field: Field,
    exact_service: ?[]const u8,
    null_terminated: bool,
) Error!void {
    var previous: ?[]const u8 = null;
    for (entries) |entry| {
        if (exact_service) |service| {
            if (!std.mem.eql(u8, entry.service, service)) continue;
        }
        const value = fieldValue(entry, field);
        if (previous) |name| {
            if (std.mem.eql(u8, name, value)) continue;
        }
        if (isUnsafeRecord(value, null_terminated)) return error.UnsafeDelimiter;
        previous = value;
    }

    previous = null;
    for (entries) |entry| {
        if (exact_service) |service| {
            if (!std.mem.eql(u8, entry.service, service)) continue;
        }
        const value = fieldValue(entry, field);
        if (previous) |name| {
            if (std.mem.eql(u8, name, value)) continue;
        }
        try writer.writeAll(value);
        try writer.writeByte(if (null_terminated) 0 else '\n');
        previous = value;
    }
}

test "human format unchanged and empty message" {
    var none_buf: [64]u8 = undefined;
    var none_writer: std.Io.Writer = .fixed(&none_buf);
    var empty: [0]types.Entry = .{};
    try writeHuman(&none_writer, &empty);
    try std.testing.expectEqualStrings("No items found.\n", none_writer.buffered());

    var entries = [_]types.Entry{
        .{ .service = "b", .account = "z", .scope = .local },
        .{ .service = "a", .account = "y", .scope = .icloud },
        .{ .service = "a", .account = "x", .scope = .local },
    };
    var text_buf: [64]u8 = undefined;
    var text_writer: std.Io.Writer = .fixed(&text_buf);
    try writeHuman(&text_writer, &entries);
    try std.testing.expectEqualStrings("a / x\na / y\nb / z\n", text_writer.buffered());
}

test "json utf8 escaping nul newline delimiter and empty array" {
    var none_buf: [8]u8 = undefined;
    var none_writer: std.Io.Writer = .fixed(&none_buf);
    var empty: [0]types.Entry = .{};
    try writeJson(&none_writer, &empty);
    try std.testing.expectEqualStrings("[]\n", none_writer.buffered());

    var entries = [_]types.Entry{
        .{ .service = "svc / delim", .account = "acc\"\\", .scope = .icloud },
        .{ .service = "unicodé", .account = "名前", .scope = .local },
        .{ .service = "new\nline", .account = "nul\x00byte", .scope = .local },
    };
    var text_buf: [256]u8 = undefined;
    var text_writer: std.Io.Writer = .fixed(&text_buf);
    try writeJson(&text_writer, &entries);
    try std.testing.expectEqualStrings(
        "[{\"service\":\"new\\nline\",\"account\":\"nul\\u0000byte\",\"scope\":\"local\"},{\"service\":\"svc / delim\",\"account\":\"acc\\\"\\\\\",\"scope\":\"icloud\"},{\"service\":\"unicodé\",\"account\":\"名前\",\"scope\":\"local\"}]\n",
        text_writer.buffered(),
    );
}

test "names and accounts dedup NUL long utf8 and exact service" {
    const long = "s" ** 300;
    var entries = [_]types.Entry{
        .{ .service = "dotfiles/a b", .account = "acc:one", .scope = .local },
        .{ .service = "dotfiles/a b", .account = "acc:one", .scope = .icloud },
        .{ .service = "dotfiles/other", .account = "acc:two", .scope = .local },
        .{ .service = long, .account = "slash/name", .scope = .local },
        .{ .service = "dotfiles/a b", .account = "acc:three", .scope = .local },
    };

    var names_buf: [512]u8 = undefined;
    var names_writer: std.Io.Writer = .fixed(&names_buf);
    try writeNames(&names_writer, &entries, true);
    try std.testing.expectEqualStrings("dotfiles/a b\x00dotfiles/other\x00" ++ long ++ "\x00", names_writer.buffered());

    var all_buf: [128]u8 = undefined;
    var all_writer: std.Io.Writer = .fixed(&all_buf);
    try writeAccounts(&all_writer, &entries, null, true);
    try std.testing.expectEqualStrings("acc:one\x00acc:three\x00acc:two\x00slash/name\x00", all_writer.buffered());

    var exact_buf: [64]u8 = undefined;
    var exact_writer: std.Io.Writer = .fixed(&exact_buf);
    try writeAccounts(&exact_writer, &entries, "dotfiles/a b", false);
    try std.testing.expectEqualStrings("acc:one\nacc:three\n", exact_writer.buffered());

    var prefix_buf: [8]u8 = undefined;
    var prefix_writer: std.Io.Writer = .fixed(&prefix_buf);
    try writeAccounts(&prefix_writer, &entries, "dotfiles", true);
    try std.testing.expectEqualStrings("", prefix_writer.buffered());

    var none_buf: [8]u8 = undefined;
    var none_writer: std.Io.Writer = .fixed(&none_buf);
    var none: [0]types.Entry = .{};
    try writeNames(&none_writer, &none, false);
    try std.testing.expectEqualStrings("", none_writer.buffered());
}

test "newline names work under --null; line and NUL formats reject unrepresentable records with no partial output" {
    var newline_entries = [_]types.Entry{
        .{ .service = "dotfiles/safe", .account = "acc", .scope = .local },
        .{ .service = "dotfiles/new\nline", .account = "acc", .scope = .icloud },
    };
    var nul_ok_buf: [64]u8 = undefined;
    var nul_ok: std.Io.Writer = .fixed(&nul_ok_buf);
    try writeNames(&nul_ok, &newline_entries, true);
    try std.testing.expectEqualStrings("dotfiles/new\nline\x00dotfiles/safe\x00", nul_ok.buffered());

    var line_buf: [64]u8 = undefined;
    var line_writer: std.Io.Writer = .fixed(&line_buf);
    try std.testing.expectError(error.UnsafeDelimiter, writeNames(&line_writer, &newline_entries, false));
    try std.testing.expectEqualStrings("", line_writer.buffered());

    var cr_entries = [_]types.Entry{
        .{ .service = "dotfiles/cr\rname", .account = "acc", .scope = .local },
    };
    var cr_buf: [64]u8 = undefined;
    var cr_writer: std.Io.Writer = .fixed(&cr_buf);
    try std.testing.expectError(error.UnsafeDelimiter, writeNames(&cr_writer, &cr_entries, false));
    try std.testing.expectEqualStrings("", cr_writer.buffered());

    var nul_entries = [_]types.Entry{
        .{ .service = "dotfiles/safe", .account = "acc", .scope = .local },
        .{ .service = "dotfiles/nul\x00byte", .account = "acc", .scope = .local },
    };
    var nul_buf: [64]u8 = undefined;
    var nul_writer: std.Io.Writer = .fixed(&nul_buf);
    try std.testing.expectError(error.UnsafeDelimiter, writeNames(&nul_writer, &nul_entries, true));
    try std.testing.expectEqualStrings("", nul_writer.buffered());

    var json_buf: [256]u8 = undefined;
    var json_writer: std.Io.Writer = .fixed(&json_buf);
    try writeJson(&json_writer, &nul_entries);
    try std.testing.expectEqualStrings(
        "[{\"service\":\"dotfiles/nul\\u0000byte\",\"account\":\"acc\",\"scope\":\"local\"},{\"service\":\"dotfiles/safe\",\"account\":\"acc\",\"scope\":\"local\"}]\n",
        json_writer.buffered(),
    );

    var account_nl = [_]types.Entry{
        .{ .service = "svc", .account = "new\nacc", .scope = .local },
        .{ .service = "svc", .account = "safe", .scope = .local },
    };
    var acc_nul_buf: [32]u8 = undefined;
    var acc_nul: std.Io.Writer = .fixed(&acc_nul_buf);
    try writeAccounts(&acc_nul, &account_nl, "svc", true);
    try std.testing.expectEqualStrings("new\nacc\x00safe\x00", acc_nul.buffered());

    var acc_line_buf: [32]u8 = undefined;
    var acc_line: std.Io.Writer = .fixed(&acc_line_buf);
    try std.testing.expectError(error.UnsafeDelimiter, writeAccounts(&acc_line, &account_nl, "svc", false));
    try std.testing.expectEqualStrings("", acc_line.buffered());
}

test "failing writer returns WriteFailed" {
    var entries = [_]types.Entry{
        .{ .service = "svc", .account = "acc", .scope = .local },
    };
    var empty: [0]types.Entry = .{};

    var human_fail: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, writeHuman(&human_fail, &empty));
    var human_fail_data: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, writeHuman(&human_fail_data, &entries));

    var json_fail: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, writeJson(&json_fail, &empty));
    var json_fail_data: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, writeJson(&json_fail_data, &entries));

    var names_fail: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, writeNames(&names_fail, &entries, true));
    var accounts_fail: std.Io.Writer = .failing;
    try std.testing.expectError(error.WriteFailed, writeAccounts(&accounts_fail, &entries, null, false));
}
