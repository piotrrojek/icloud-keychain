const std = @import("std");
const types = @import("types.zig");

pub const stdin_max_size: usize = 4 * 1024 * 1024;

pub const ParseError = error{
    Usage,
    UnknownCommand,
    UnexpectedFlag,
    DuplicateFlag,
    ConflictingFlags,
    ExtraArguments,
    MissingArguments,
    InvalidScope,
    ScopeAnyForbidden,
    ScopeRequired,
    EmptyPassword,
    EmptyIdentifier,
    RawNotAllowed,
    NullNotAllowed,
};

pub const Password = union(enum) {
    argv: []const u8,
    stdin,
};

pub const ListMode = enum { human, json, names_only, accounts_only };

pub const SetArgs = struct {
    service: []const u8,
    account: []const u8,
    password: Password,
    scope: types.Scope,
    allow_empty: bool = false,
    raw: bool = false,
};

pub const GetArgs = struct {
    service: []const u8,
    account: []const u8,
    scope: types.Scope,
    raw: bool = false,
};

pub const DeleteArgs = struct {
    service: []const u8,
    account: []const u8,
    scope: types.Scope,
};

pub const ListArgs = struct {
    filter: ?[]const u8 = null,
    scope: types.Scope,
    mode: ListMode = .human,
    null_terminated: bool = false,
};

pub const Command = union(enum) {
    help,
    version,
    set: SetArgs,
    get: GetArgs,
    delete: DeleteArgs,
    list: ListArgs,
    doctor,
};

pub const usage_text =
    \\Usage:
    \\  icloud-keychain set [options] <service> <account> [<password>|-]
    \\  icloud-keychain get [options] <service> <account>
    \\  icloud-keychain delete [options] <service> <account>
    \\  icloud-keychain list [options] [filter]
    \\  icloud-keychain doctor
    \\  icloud-keychain --help | -h
    \\  icloud-keychain --version | -v
    \\
    \\Scope (after the subcommand, any position; `--` ends options):
    \\  --scope local|icloud|any   also --scope=...
    \\  --local                    alias for --scope local
    \\  --sync                     alias for --scope icloud
    \\
    \\  set defaults to local and rejects --scope any
    \\  get and list default to any
    \\  delete requires explicit local or icloud and rejects any
    \\
    \\set:
    \\  --stdin              read password from stdin (no password positional)
    \\  -                    password sentinel; same as --stdin
    \\  --raw                keep stdin bytes exactly (set stdin / get only)
    \\  --allow-empty        allow an empty password after normalization
    \\
    \\get:
    \\  --raw                write the secret with no added newline
    \\
    \\list:
    \\  --json               UTF-8 JSON array of {service,account,scope}
    \\  --names-only         unique service names
    \\  --accounts-only      unique account names; optional argument is an
    \\                       EXACT service match, not a prefix
    \\  --null               NUL-terminate names/accounts (not with --json)
    \\  filter               service prefix, except --accounts-only (exact)
    \\
    \\Stdin secrets are capped at 4 MiB. Default stdin mode trims one trailing
    \\LF or CRLF; --raw keeps bytes exactly. get/list --scope any fails if a
    \\store is unavailable. Unsigned binaries should use --local.
    \\
    \\Flags starting with '-' are options, not secrets, unless after `--`.
    \\Unknown, duplicate, conflicting, or extra arguments are errors.
    \\
;

const max_positionals = 8;

const Cursor = struct {
    args: []const []const u8,
    index: usize = 0,
    options_ended: bool = false,

    fn nextRaw(self: *Cursor) ?[]const u8 {
        if (self.index >= self.args.len) return null;
        const arg = self.args[self.index];
        self.index += 1;
        return arg;
    }
};

const Token = union(enum) {
    flag: []const u8,
    positional: []const u8,
};

fn isFlag(arg: []const u8) bool {
    return arg.len >= 2 and arg[0] == '-';
}

fn nextToken(cursor: *Cursor) ?Token {
    while (true) {
        const arg = cursor.nextRaw() orelse return null;
        if (!cursor.options_ended) {
            if (std.mem.eql(u8, arg, "--")) {
                cursor.options_ended = true;
                continue;
            }
            if (isFlag(arg)) return .{ .flag = arg };
        }
        return .{ .positional = arg };
    }
}

fn flagParts(arg: []const u8) struct { name: []const u8, value: ?[]const u8 } {
    if (std.mem.startsWith(u8, arg, "--")) {
        if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
            return .{ .name = arg[0..eq], .value = arg[eq + 1 ..] };
        }
    }
    return .{ .name = arg, .value = null };
}

fn rejectInlineValue(value: ?[]const u8) ParseError!void {
    if (value != null) return error.UnexpectedFlag;
}

fn parseScopeValue(value: []const u8) ParseError!types.Scope {
    if (std.mem.eql(u8, value, "local")) return .local;
    if (std.mem.eql(u8, value, "icloud")) return .icloud;
    if (std.mem.eql(u8, value, "any")) return .any;
    return error.InvalidScope;
}

const ScopeSeen = enum { none, local, icloud, any };

fn applyScope(seen: *ScopeSeen, next: types.Scope) ParseError!void {
    const mapped: ScopeSeen = switch (next) {
        .local => .local,
        .icloud => .icloud,
        .any => .any,
    };
    if (seen.* == .none) {
        seen.* = mapped;
        return;
    }
    if (seen.* == mapped) return error.DuplicateFlag;
    return error.ConflictingFlags;
}

fn setFlag(flag: *bool) ParseError!void {
    if (flag.*) return error.DuplicateFlag;
    flag.* = true;
}

fn takeScopeValue(cursor: *Cursor, inline_value: ?[]const u8) ParseError![]const u8 {
    if (inline_value) |value| return value;
    return cursor.nextRaw() orelse error.MissingArguments;
}

fn requireIdent(value: []const u8) ParseError![]const u8 {
    if (value.len == 0) return error.EmptyIdentifier;
    return value;
}

fn finishHelp(help: bool, any_other: bool, positional_len: usize) ParseError!?Command {
    if (!help) return null;
    if (any_other or positional_len != 0) return error.ExtraArguments;
    return .help;
}

fn appendPositional(buf: *[max_positionals][]const u8, len: *usize, value: []const u8) ParseError!void {
    if (len.* >= buf.len) return error.ExtraArguments;
    buf[len.*] = value;
    len.* += 1;
}

pub fn parse(args: []const []const u8) ParseError!Command {
    if (args.len < 2) return error.Usage;

    const cmd = args[1];
    if (isHelpFlag(cmd)) {
        if (args.len != 2) return error.ExtraArguments;
        return .help;
    }
    if (isVersionFlag(cmd)) {
        if (args.len != 2) return error.ExtraArguments;
        return .version;
    }

    var cursor: Cursor = .{ .args = args, .index = 2 };
    if (std.mem.eql(u8, cmd, "set")) return parseSet(&cursor);
    if (std.mem.eql(u8, cmd, "get")) return parseGet(&cursor);
    if (std.mem.eql(u8, cmd, "delete")) return parseDelete(&cursor);
    if (std.mem.eql(u8, cmd, "list")) return parseList(&cursor);
    if (std.mem.eql(u8, cmd, "doctor")) return parseDoctor(&cursor);
    return error.UnknownCommand;
}

fn isHelpFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h");
}

fn isVersionFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-v");
}

fn parseSet(cursor: *Cursor) ParseError!Command {
    var scope_seen: ScopeSeen = .none;
    var stdin = false;
    var raw = false;
    var allow_empty = false;
    var help = false;
    var positionals: [max_positionals][]const u8 = undefined;
    var positional_len: usize = 0;

    while (nextToken(cursor)) |token| switch (token) {
        .flag => |arg| {
            const parts = flagParts(arg);
            if (isHelpFlag(parts.name)) {
                try rejectInlineValue(parts.value);
                try setFlag(&help);
            } else if (std.mem.eql(u8, parts.name, "--sync")) {
                try rejectInlineValue(parts.value);
                try applyScope(&scope_seen, .icloud);
            } else if (std.mem.eql(u8, parts.name, "--local")) {
                try rejectInlineValue(parts.value);
                try applyScope(&scope_seen, .local);
            } else if (std.mem.eql(u8, parts.name, "--scope")) {
                try applyScope(&scope_seen, try parseScopeValue(try takeScopeValue(cursor, parts.value)));
            } else if (std.mem.eql(u8, parts.name, "--stdin")) {
                try rejectInlineValue(parts.value);
                try setFlag(&stdin);
            } else if (std.mem.eql(u8, parts.name, "--raw")) {
                try rejectInlineValue(parts.value);
                try setFlag(&raw);
            } else if (std.mem.eql(u8, parts.name, "--allow-empty")) {
                try rejectInlineValue(parts.value);
                try setFlag(&allow_empty);
            } else {
                return error.UnexpectedFlag;
            }
        },
        .positional => |value| try appendPositional(&positionals, &positional_len, value),
    };

    const other = scope_seen != .none or stdin or raw or allow_empty;
    if (try finishHelp(help, other, positional_len)) |command| return command;

    const scope: types.Scope = switch (scope_seen) {
        .none, .local => .local,
        .icloud => .icloud,
        .any => return error.ScopeAnyForbidden,
    };

    const password: Password = if (stdin) blk: {
        if (positional_len != 2) {
            return if (positional_len < 2) error.MissingArguments else error.ExtraArguments;
        }
        break :blk .stdin;
    } else blk: {
        if (positional_len < 3) return error.MissingArguments;
        if (positional_len > 3) return error.ExtraArguments;
        const secret = positionals[2];
        if (std.mem.eql(u8, secret, "-")) break :blk .stdin;
        if (!allow_empty and secret.len == 0) return error.EmptyPassword;
        break :blk .{ .argv = secret };
    };

    if (raw and password != .stdin) return error.RawNotAllowed;

    return .{ .set = .{
        .service = try requireIdent(positionals[0]),
        .account = try requireIdent(positionals[1]),
        .password = password,
        .scope = scope,
        .allow_empty = allow_empty,
        .raw = raw,
    } };
}

fn parseGet(cursor: *Cursor) ParseError!Command {
    var scope_seen: ScopeSeen = .none;
    var raw = false;
    var help = false;
    var positionals: [max_positionals][]const u8 = undefined;
    var positional_len: usize = 0;

    while (nextToken(cursor)) |token| switch (token) {
        .flag => |arg| {
            const parts = flagParts(arg);
            if (isHelpFlag(parts.name)) {
                try rejectInlineValue(parts.value);
                try setFlag(&help);
            } else if (std.mem.eql(u8, parts.name, "--sync")) {
                try rejectInlineValue(parts.value);
                try applyScope(&scope_seen, .icloud);
            } else if (std.mem.eql(u8, parts.name, "--local")) {
                try rejectInlineValue(parts.value);
                try applyScope(&scope_seen, .local);
            } else if (std.mem.eql(u8, parts.name, "--scope")) {
                try applyScope(&scope_seen, try parseScopeValue(try takeScopeValue(cursor, parts.value)));
            } else if (std.mem.eql(u8, parts.name, "--raw")) {
                try rejectInlineValue(parts.value);
                try setFlag(&raw);
            } else {
                return error.UnexpectedFlag;
            }
        },
        .positional => |value| try appendPositional(&positionals, &positional_len, value),
    };

    const other = scope_seen != .none or raw;
    if (try finishHelp(help, other, positional_len)) |command| return command;
    if (positional_len < 2) return error.MissingArguments;
    if (positional_len > 2) return error.ExtraArguments;

    const scope: types.Scope = switch (scope_seen) {
        .none, .any => .any,
        .local => .local,
        .icloud => .icloud,
    };

    return .{ .get = .{
        .service = try requireIdent(positionals[0]),
        .account = try requireIdent(positionals[1]),
        .scope = scope,
        .raw = raw,
    } };
}

fn parseDelete(cursor: *Cursor) ParseError!Command {
    var scope_seen: ScopeSeen = .none;
    var help = false;
    var positionals: [max_positionals][]const u8 = undefined;
    var positional_len: usize = 0;

    while (nextToken(cursor)) |token| switch (token) {
        .flag => |arg| {
            const parts = flagParts(arg);
            if (isHelpFlag(parts.name)) {
                try rejectInlineValue(parts.value);
                try setFlag(&help);
            } else if (std.mem.eql(u8, parts.name, "--sync")) {
                try rejectInlineValue(parts.value);
                try applyScope(&scope_seen, .icloud);
            } else if (std.mem.eql(u8, parts.name, "--local")) {
                try rejectInlineValue(parts.value);
                try applyScope(&scope_seen, .local);
            } else if (std.mem.eql(u8, parts.name, "--scope")) {
                try applyScope(&scope_seen, try parseScopeValue(try takeScopeValue(cursor, parts.value)));
            } else {
                return error.UnexpectedFlag;
            }
        },
        .positional => |value| try appendPositional(&positionals, &positional_len, value),
    };

    if (try finishHelp(help, scope_seen != .none, positional_len)) |command| return command;
    if (positional_len < 2) return error.MissingArguments;
    if (positional_len > 2) return error.ExtraArguments;

    const scope: types.Scope = switch (scope_seen) {
        .none => return error.ScopeRequired,
        .any => return error.ScopeAnyForbidden,
        .local => .local,
        .icloud => .icloud,
    };

    return .{ .delete = .{
        .service = try requireIdent(positionals[0]),
        .account = try requireIdent(positionals[1]),
        .scope = scope,
    } };
}

fn parseList(cursor: *Cursor) ParseError!Command {
    var scope_seen: ScopeSeen = .none;
    var json = false;
    var names_only = false;
    var accounts_only = false;
    var nul = false;
    var help = false;
    var positionals: [max_positionals][]const u8 = undefined;
    var positional_len: usize = 0;

    while (nextToken(cursor)) |token| switch (token) {
        .flag => |arg| {
            const parts = flagParts(arg);
            if (isHelpFlag(parts.name)) {
                try rejectInlineValue(parts.value);
                try setFlag(&help);
            } else if (std.mem.eql(u8, parts.name, "--sync")) {
                try rejectInlineValue(parts.value);
                try applyScope(&scope_seen, .icloud);
            } else if (std.mem.eql(u8, parts.name, "--local")) {
                try rejectInlineValue(parts.value);
                try applyScope(&scope_seen, .local);
            } else if (std.mem.eql(u8, parts.name, "--scope")) {
                try applyScope(&scope_seen, try parseScopeValue(try takeScopeValue(cursor, parts.value)));
            } else if (std.mem.eql(u8, parts.name, "--json")) {
                try rejectInlineValue(parts.value);
                try setFlag(&json);
            } else if (std.mem.eql(u8, parts.name, "--names-only")) {
                try rejectInlineValue(parts.value);
                try setFlag(&names_only);
            } else if (std.mem.eql(u8, parts.name, "--accounts-only")) {
                try rejectInlineValue(parts.value);
                try setFlag(&accounts_only);
            } else if (std.mem.eql(u8, parts.name, "--null")) {
                try rejectInlineValue(parts.value);
                try setFlag(&nul);
            } else {
                return error.UnexpectedFlag;
            }
        },
        .positional => |value| try appendPositional(&positionals, &positional_len, value),
    };

    const other = scope_seen != .none or json or names_only or accounts_only or nul;
    if (try finishHelp(help, other, positional_len)) |command| return command;
    if (positional_len > 1) return error.ExtraArguments;

    const modes = @as(u8, @intFromBool(json)) + @as(u8, @intFromBool(names_only)) + @as(u8, @intFromBool(accounts_only));
    if (modes > 1) return error.ConflictingFlags;
    if (nul and !names_only and !accounts_only) return error.NullNotAllowed;

    const mode: ListMode = if (json) .json else if (names_only) .names_only else if (accounts_only) .accounts_only else .human;
    const scope: types.Scope = switch (scope_seen) {
        .none, .any => .any,
        .local => .local,
        .icloud => .icloud,
    };
    const filter: ?[]const u8 = if (positional_len == 1) positionals[0] else null;

    return .{ .list = .{
        .filter = filter,
        .scope = scope,
        .mode = mode,
        .null_terminated = nul,
    } };
}

fn parseDoctor(cursor: *Cursor) ParseError!Command {
    var help = false;
    var extra = false;
    while (nextToken(cursor)) |token| switch (token) {
        .flag => |arg| {
            const parts = flagParts(arg);
            if (isHelpFlag(parts.name)) {
                try rejectInlineValue(parts.value);
                try setFlag(&help);
            } else {
                return error.UnexpectedFlag;
            }
        },
        .positional => extra = true,
    };
    if (try finishHelp(help, extra, 0)) |command| return command;
    if (extra) return error.ExtraArguments;
    return .doctor;
}

pub const SecretBuffer = struct {
    allocator: std.mem.Allocator,
    storage: []u8,
    value: []u8,

    pub fn deinit(self: *SecretBuffer) void {
        wipe(self.storage);
        self.allocator.free(self.storage);
        self.* = undefined;
    }
};

pub fn wipe(bytes: []u8) void {
    std.crypto.secureZero(u8, @as([]volatile u8, @ptrCast(bytes)));
}

pub fn validatePassword(value: []const u8, allow_empty: bool) ParseError!void {
    if (value.len == 0 and !allow_empty) return error.EmptyPassword;
}

pub fn readStdinSecret(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    raw: bool,
) !SecretBuffer {
    return readStdinSecretCapped(allocator, reader, raw, stdin_max_size);
}

pub fn readStdinSecretCapped(
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    raw: bool,
    cap: usize,
) !SecretBuffer {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer {
        wipe(aw.writer.buffered());
        aw.deinit();
    }

    var remaining = cap + 1;
    while (remaining > 0) {
        const n = reader.stream(&aw.writer, .limited(remaining)) catch |err| switch (err) {
            error.EndOfStream => break,
            error.WriteFailed => return error.OutOfMemory,
            error.ReadFailed => return error.ReadFailed,
        };
        remaining -= n;
    }
    if (remaining == 0) return error.StreamTooLong;

    const storage = try aw.toOwnedSlice();
    errdefer {
        wipe(storage);
        allocator.free(storage);
    }

    var len = storage.len;
    if (!raw) {
        if (len > 0 and storage[len - 1] == '\n') {
            len -= 1;
            if (len > 0 and storage[len - 1] == '\r') len -= 1;
        }
    }

    return .{
        .allocator = allocator,
        .storage = storage,
        .value = storage[0..len],
    };
}

fn expectSet(args: []const []const u8) !SetArgs {
    const command = try parse(args);
    return command.set;
}

fn expectGet(args: []const []const u8) !GetArgs {
    const command = try parse(args);
    return command.get;
}

fn expectDelete(args: []const []const u8) !DeleteArgs {
    const command = try parse(args);
    return command.delete;
}

fn expectList(args: []const []const u8) !ListArgs {
    const command = try parse(args);
    return command.list;
}

test "set defaults to local argv password" {
    const cmd = try expectSet(&.{ "ik", "set", "svc", "acc", "pw" });
    try std.testing.expectEqual(types.Scope.local, cmd.scope);
    try std.testing.expectEqualStrings("svc", cmd.service);
    try std.testing.expectEqualStrings("acc", cmd.account);
    try std.testing.expectEqualStrings("pw", cmd.password.argv);
    try std.testing.expect(!cmd.raw);
}

test "set flags anywhere including aliases and equals scope" {
    const sync = try expectSet(&.{ "ik", "set", "svc", "acc", "pw", "--sync" });
    try std.testing.expectEqual(types.Scope.icloud, sync.scope);

    const local = try expectSet(&.{ "ik", "set", "--local", "svc", "acc", "pw" });
    try std.testing.expectEqual(types.Scope.local, local.scope);

    const eq = try expectSet(&.{ "ik", "set", "--scope=icloud", "svc", "acc", "pw" });
    try std.testing.expectEqual(types.Scope.icloud, eq.scope);

    const spaced = try expectSet(&.{ "ik", "set", "svc", "--scope", "local", "acc", "pw" });
    try std.testing.expectEqual(types.Scope.local, spaced.scope);
}

test "set rejects any, duplicates, conflicts, extras, unknown flags" {
    try std.testing.expectError(error.ScopeAnyForbidden, parse(&.{ "ik", "set", "--scope", "any", "s", "a", "p" }));
    try std.testing.expectError(error.DuplicateFlag, parse(&.{ "ik", "set", "--sync", "--sync", "s", "a", "p" }));
    try std.testing.expectError(error.DuplicateFlag, parse(&.{ "ik", "set", "--scope", "local", "--local", "s", "a", "p" }));
    try std.testing.expectError(error.ConflictingFlags, parse(&.{ "ik", "set", "--local", "--sync", "s", "a", "p" }));
    try std.testing.expectError(error.UnexpectedFlag, parse(&.{ "ik", "set", "--bogus", "s", "a", "p" }));
    try std.testing.expectError(error.UnexpectedFlag, parse(&.{ "ik", "set", "s", "a", "-secret" }));
    try std.testing.expectError(error.ExtraArguments, parse(&.{ "ik", "set", "s", "a", "p", "extra" }));
    try std.testing.expectError(error.MissingArguments, parse(&.{ "ik", "set", "s", "a" }));
    try std.testing.expectError(error.InvalidScope, parse(&.{ "ik", "set", "--scope", "LOCAL", "s", "a", "p" }));
    try std.testing.expectError(error.EmptyPassword, parse(&.{ "ik", "set", "s", "a", "" }));
    try std.testing.expectError(error.EmptyIdentifier, parse(&.{ "ik", "set", "", "a", "p" }));
}

test "set stdin modes and raw" {
    const dash = try expectSet(&.{ "ik", "set", "s", "a", "-" });
    try std.testing.expect(dash.password == .stdin);

    const flag = try expectSet(&.{ "ik", "set", "--stdin", "s", "a" });
    try std.testing.expect(flag.password == .stdin);

    const raw = try expectSet(&.{ "ik", "set", "--raw", "--stdin", "s", "a" });
    try std.testing.expect(raw.raw);
    try std.testing.expect(raw.password == .stdin);

    const raw_dash = try expectSet(&.{ "ik", "set", "--raw", "s", "a", "-" });
    try std.testing.expect(raw_dash.raw);

    try std.testing.expectError(error.RawNotAllowed, parse(&.{ "ik", "set", "--raw", "s", "a", "pw" }));
    try std.testing.expectError(error.ExtraArguments, parse(&.{ "ik", "set", "--stdin", "s", "a", "-" }));
    try std.testing.expectError(error.MissingArguments, parse(&.{ "ik", "set", "--stdin", "s" }));
}

test "set -- terminates options so dashed secrets are positionals" {
    const cmd = try expectSet(&.{ "ik", "set", "--", "--svc", "--acc", "--pw" });
    try std.testing.expectEqualStrings("--svc", cmd.service);
    try std.testing.expectEqualStrings("--acc", cmd.account);
    try std.testing.expectEqualStrings("--pw", cmd.password.argv);
}

test "set --allow-empty accepts empty argv" {
    const cmd = try expectSet(&.{ "ik", "set", "--allow-empty", "s", "a", "" });
    try std.testing.expect(cmd.allow_empty);
    try std.testing.expectEqualStrings("", cmd.password.argv);
}

test "get defaults to any and accepts raw anywhere" {
    const cmd = try expectGet(&.{ "ik", "get", "s", "a", "--raw" });
    try std.testing.expectEqual(types.Scope.any, cmd.scope);
    try std.testing.expect(cmd.raw);

    const scoped = try expectGet(&.{ "ik", "get", "--scope=local", "s", "a" });
    try std.testing.expectEqual(types.Scope.local, scoped.scope);
    try std.testing.expectError(error.UnexpectedFlag, parse(&.{ "ik", "get", "--stdin", "s", "a" }));
    try std.testing.expectError(error.MissingArguments, parse(&.{ "ik", "get", "s" }));
}

test "delete requires explicit local or icloud" {
    try std.testing.expectError(error.ScopeRequired, parse(&.{ "ik", "delete", "s", "a" }));
    try std.testing.expectError(error.ScopeAnyForbidden, parse(&.{ "ik", "delete", "--scope", "any", "s", "a" }));
    const local = try expectDelete(&.{ "ik", "delete", "s", "--local", "a" });
    try std.testing.expectEqual(types.Scope.local, local.scope);
    const icloud = try expectDelete(&.{ "ik", "delete", "--sync", "s", "a" });
    try std.testing.expectEqual(types.Scope.icloud, icloud.scope);
}

test "list modes conflict and --null is names/accounts only" {
    const human = try expectList(&.{ "ik", "list", "pref" });
    try std.testing.expectEqual(ListMode.human, human.mode);
    try std.testing.expectEqualStrings("pref", human.filter.?);
    try std.testing.expectEqual(types.Scope.any, human.scope);

    const json = try expectList(&.{ "ik", "list", "--json" });
    try std.testing.expectEqual(ListMode.json, json.mode);

    const names = try expectList(&.{ "ik", "list", "--names-only", "--null" });
    try std.testing.expectEqual(ListMode.names_only, names.mode);
    try std.testing.expect(names.null_terminated);

    const accounts = try expectList(&.{ "ik", "list", "--accounts-only", "exact/service" });
    try std.testing.expectEqual(ListMode.accounts_only, accounts.mode);
    try std.testing.expectEqualStrings("exact/service", accounts.filter.?);

    try std.testing.expectError(error.ConflictingFlags, parse(&.{ "ik", "list", "--json", "--names-only" }));
    try std.testing.expectError(error.ConflictingFlags, parse(&.{ "ik", "list", "--names-only", "--accounts-only" }));
    try std.testing.expectError(error.NullNotAllowed, parse(&.{ "ik", "list", "--null" }));
    try std.testing.expectError(error.NullNotAllowed, parse(&.{ "ik", "list", "--json", "--null" }));
    try std.testing.expectError(error.ExtraArguments, parse(&.{ "ik", "list", "a", "b" }));
}

test "help and version arity" {
    try std.testing.expectEqual(Command.help, try parse(&.{ "ik", "--help" }));
    try std.testing.expectEqual(Command.help, try parse(&.{ "ik", "-h" }));
    try std.testing.expectEqual(Command.version, try parse(&.{ "ik", "--version" }));
    try std.testing.expectEqual(Command.version, try parse(&.{ "ik", "-v" }));
    try std.testing.expectError(error.ExtraArguments, parse(&.{ "ik", "--help", "set" }));
    try std.testing.expectError(error.ExtraArguments, parse(&.{ "ik", "--version", "1" }));
    try std.testing.expectEqual(Command.help, try parse(&.{ "ik", "set", "--help" }));
    try std.testing.expectEqual(Command.help, try parse(&.{ "ik", "list", "-h" }));
    try std.testing.expectError(error.ExtraArguments, parse(&.{ "ik", "set", "--help", "--sync" }));
    try std.testing.expectError(error.ExtraArguments, parse(&.{ "ik", "get", "s", "--help" }));
    try std.testing.expectError(error.Usage, parse(&.{"ik"}));
    try std.testing.expectError(error.UnknownCommand, parse(&.{ "ik", "explode" }));
}

test "doctor rejects extra flags and args" {
    try std.testing.expectEqual(Command.doctor, try parse(&.{ "ik", "doctor" }));
    try std.testing.expectEqual(Command.help, try parse(&.{ "ik", "doctor", "--help" }));
    try std.testing.expectError(error.UnexpectedFlag, parse(&.{ "ik", "doctor", "--sync" }));
    try std.testing.expectError(error.ExtraArguments, parse(&.{ "ik", "doctor", "x" }));
}

test "stdin trim raw and limit" {
    const allocator = std.testing.allocator;

    {
        var reader: std.Io.Reader = .fixed("secret\n");
        var secret = try readStdinSecretCapped(allocator, &reader, false, 64);
        defer secret.deinit();
        try std.testing.expectEqualStrings("secret", secret.value);
        try std.testing.expectEqual(@as(usize, 7), secret.storage.len);
    }
    {
        var reader: std.Io.Reader = .fixed("secret\r\n");
        var secret = try readStdinSecretCapped(allocator, &reader, false, 64);
        defer secret.deinit();
        try std.testing.expectEqualStrings("secret", secret.value);
    }
    {
        var reader: std.Io.Reader = .fixed("secret\n\n");
        var secret = try readStdinSecretCapped(allocator, &reader, false, 64);
        defer secret.deinit();
        try std.testing.expectEqualStrings("secret\n", secret.value);
    }
    {
        var reader: std.Io.Reader = .fixed("secret\n");
        var secret = try readStdinSecretCapped(allocator, &reader, true, 64);
        defer secret.deinit();
        try std.testing.expectEqualStrings("secret\n", secret.value);
    }
    {
        var reader: std.Io.Reader = .fixed("");
        var secret = try readStdinSecretCapped(allocator, &reader, false, 64);
        defer secret.deinit();
        try std.testing.expectEqualStrings("", secret.value);
        try std.testing.expectError(error.EmptyPassword, validatePassword(secret.value, false));
        try validatePassword(secret.value, true);
    }
    {
        var reader: std.Io.Reader = .fixed("123456789");
        try std.testing.expectError(error.StreamTooLong, readStdinSecretCapped(allocator, &reader, true, 8));
    }
    {
        var reader: std.Io.Reader = .fixed("12345678");
        var secret = try readStdinSecretCapped(allocator, &reader, true, 8);
        defer secret.deinit();
        try std.testing.expectEqualStrings("12345678", secret.value);
    }
}
