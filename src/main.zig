// icloud-keychain — macOS Keychain CLI with iCloud sync.
// Copyright (c) 2026 Piotr Rojek — https://piotrrojek.io
// MIT License

const std = @import("std");
const build_options = @import("build_options");
const keychain = @import("keychain.zig");
const types = @import("types.zig");
const cli = @import("cli.zig");
const output = @import("output.zig");
const doctor = @import("doctor.zig");

pub fn main() void {
    std.process.exit(run());
}

fn run() u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = std.process.argsAlloc(allocator) catch return fail(error.OutOfMemory);
    defer std.process.argsFree(allocator, args);

    const command = cli.parse(args) catch |err| {
        if (err == error.Usage) {
            writeAll(.stderr, cli.usage_text) catch {};
            return 1;
        }
        return fail(err);
    };

    switch (command) {
        .help => {
            writeAll(.stdout, cli.usage_text) catch return fail(error.WriteFailed);
            return 0;
        },
        .version => {
            printVersion() catch return fail(error.WriteFailed);
            return 0;
        },
        .set => |set| return runSet(allocator, set),
        .get => |get| return runGet(allocator, get),
        .delete => |delete| return runDelete(delete),
        .list => |list| return runList(allocator, list),
        .doctor => return runDoctor(allocator),
    }
}

fn runSet(allocator: std.mem.Allocator, set: cli.SetArgs) u8 {
    switch (set.password) {
        .argv => |password| {
            cli.validatePassword(password, set.allow_empty) catch |err| return fail(err);
            defer cli.wipe(@constCast(password));
            keychain.set(set.service, set.account, password, set.scope) catch |err| return fail(err);
        },
        .stdin => {
            var secret = readStdin(allocator, set.raw) catch |err| return fail(err);
            defer secret.deinit();
            cli.validatePassword(secret.value, set.allow_empty) catch |err| return fail(err);
            keychain.set(set.service, set.account, secret.value, set.scope) catch |err| return fail(err);
        },
    }

    const where: []const u8 = switch (set.scope) {
        .icloud => "iCloud Keychain",
        .local, .any => "local Keychain",
    };
    print(.stderr, "Stored {s} / {s} in {s}.\n", .{ set.service, set.account, where }) catch {};
    return 0;
}

fn runGet(allocator: std.mem.Allocator, get: cli.GetArgs) u8 {
    const password = keychain.get(allocator, get.service, get.account, get.scope) catch |err| return fail(err);
    defer {
        cli.wipe(password);
        allocator.free(password);
    }

    var buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buf);
    const stdout: *std.Io.Writer = &stdout_writer.interface;
    stdout.writeAll(password) catch return fail(error.WriteFailed);
    if (!get.raw) stdout.writeAll("\n") catch return fail(error.WriteFailed);
    stdout.flush() catch return fail(error.WriteFailed);
    return 0;
}

fn runDelete(delete: cli.DeleteArgs) u8 {
    keychain.delete(delete.service, delete.account, delete.scope) catch |err| return fail(err);
    print(.stderr, "Deleted {s} / {s} from Keychain.\n", .{ delete.service, delete.account }) catch {};
    return 0;
}

fn runList(allocator: std.mem.Allocator, list: cli.ListArgs) u8 {
    const prefix = list.filter;
    const entries = keychain.list(allocator, prefix, list.scope) catch |err| return fail(err);
    defer types.freeEntries(allocator, entries);

    var buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buf);
    const stdout: *std.Io.Writer = &stdout_writer.interface;
    switch (list.mode) {
        .human => output.writeHuman(stdout, entries) catch |err| return fail(err),
        .json => output.writeJson(stdout, entries) catch |err| return fail(err),
        .names_only => output.writeNames(stdout, entries, list.null_terminated) catch |err| return fail(err),
        .accounts_only => {
            const exact = list.filter;
            output.writeAccounts(stdout, entries, exact, list.null_terminated) catch |err| return fail(err);
        },
    }
    stdout.flush() catch return fail(error.WriteFailed);
    return 0;
}

fn runDoctor(allocator: std.mem.Allocator) u8 {
    var buf: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buf);
    const stdout: *std.Io.Writer = &stdout_writer.interface;
    const ok = doctor.run(allocator, stdout) catch |err| return fail(err);
    stdout.flush() catch return fail(error.WriteFailed);
    return if (ok) 0 else 1;
}

fn readStdin(allocator: std.mem.Allocator, raw: bool) !cli.SecretBuffer {
    var buf: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&buf);
    return cli.readStdinSecret(allocator, &stdin_reader.interface, raw);
}

fn printVersion() std.Io.Writer.Error!void {
    try print(.stdout, "icloud-keychain {s}\n", .{build_options.version});
}

const Stream = enum { stdout, stderr };

fn print(stream: Stream, comptime fmt: []const u8, args: anytype) std.Io.Writer.Error!void {
    var buf: [1024]u8 = undefined;
    var writer = switch (stream) {
        .stdout => std.fs.File.stdout().writer(&buf),
        .stderr => std.fs.File.stderr().writer(&buf),
    };
    try writer.interface.print(fmt, args);
    try writer.interface.flush();
}

fn writeAll(stream: Stream, bytes: []const u8) std.Io.Writer.Error!void {
    var buf: [1024]u8 = undefined;
    var writer = switch (stream) {
        .stdout => std.fs.File.stdout().writer(&buf),
        .stderr => std.fs.File.stderr().writer(&buf),
    };
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn fail(err: anyerror) u8 {
    const message: []const u8 = switch (err) {
        error.MissingEntitlement => "Error: MissingEntitlement\nUse a signed app bundle (icloud-keychain doctor) or --local.\n",
        error.InteractionNotAllowed => "Error: InteractionNotAllowed\nUnlock the login keychain / user session and retry.\n",
        error.AmbiguousItem => "Error: AmbiguousItem\nSpecify --scope local or --sync.\n",
        error.ScopeRequired => "Error: ScopeRequired\nPass --local or --sync (delete never uses any).\n",
        error.EmptyPassword => "Error: EmptyPassword\nPass --allow-empty only if an empty secret is intentional.\n",
        error.UnsafeDelimiter => "Error: UnsafeDelimiter\nUse --json for names that contain newlines or NULs.\n",
        else => "",
    };
    if (message.len != 0) {
        writeAll(.stderr, message) catch {};
    } else {
        print(.stderr, "Error: {s}\n", .{@errorName(err)}) catch {};
    }
    return 1;
}
