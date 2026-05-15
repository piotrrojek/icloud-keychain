// icloud-keychain — macOS Keychain CLI with iCloud sync.
// Copyright (c) 2026 Piotr Rojek — https://piotrrojek.io
// MIT License

const std = @import("std");
const keychain = @import("keychain.zig");

const stdout_file = std.fs.File.stdout();

// Hard cap on stdin-piped secrets — Keychain itself enforces tighter limits,
// but we want to refuse runaway pipes early.
const stdin_max_size: usize = 4 * 1024 * 1024;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) usage();

    const cmd = args[1];

    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        try stdout_file.writeAll("icloud-keychain 1.0.0\nPiotr Rojek — https://piotrrojek.io\n");
        return;
    }

    if (std.mem.eql(u8, cmd, "set")) {
        // Parse optional --sync flag
        var sync = false;
        var pos: usize = 2;
        if (pos < args.len and std.mem.eql(u8, args[pos], "--sync")) {
            sync = true;
            pos += 1;
        }
        if (args.len < pos + 3) usage();

        const service = args[pos];
        const account = args[pos + 1];
        const password_arg = args[pos + 2];

        const password: []const u8 = if (std.mem.eql(u8, password_arg, "-"))
            readStdinPassword(allocator) catch |err| {
                std.debug.print("Error reading password from stdin: {}\n", .{err});
                std.process.exit(1);
            }
        else
            password_arg;
        defer if (password.ptr != password_arg.ptr) allocator.free(password);

        keychain.set(service, account, password, sync) catch |err| {
            if (err == keychain.KeychainError.MissingEntitlement) {
                std.debug.print("Error: missing entitlement. iCloud sync requires a provisioned App ID.\n" ++
                    "Run without --sync to use the local keychain instead.\n", .{});
            } else {
                std.debug.print("Error: {}\n", .{err});
            }
            std.process.exit(1);
        };
        const where: []const u8 = if (sync) "iCloud Keychain" else "local Keychain";
        std.debug.print("Stored {s} / {s} in {s}.\n", .{ service, account, where });
    } else if (std.mem.eql(u8, cmd, "get")) {
        if (args.len < 4) usage();
        const password = keychain.get(allocator, args[2], args[3]) catch |err| {
            std.debug.print("Error: {}\n", .{err});
            std.process.exit(1);
        };
        defer allocator.free(password);
        try stdout_file.writeAll(password);
        try stdout_file.writeAll("\n");
    } else if (std.mem.eql(u8, cmd, "delete")) {
        if (args.len < 4) usage();
        keychain.delete(args[2], args[3]) catch |err| {
            std.debug.print("Error: {}\n", .{err});
            std.process.exit(1);
        };
        std.debug.print("Deleted {s} / {s} from Keychain.\n", .{ args[2], args[3] });
    } else if (std.mem.eql(u8, cmd, "list")) {
        const filter: ?[]const u8 = if (args.len >= 3) args[2] else null;
        keychain.list(filter) catch |err| {
            std.debug.print("Error: {}\n", .{err});
            std.process.exit(1);
        };
    } else {
        usage();
    }
}

/// Read all of stdin into a caller-owned slice. A single trailing `\n` (or
/// `\r\n`) is stripped — matches `gh auth login --with-token` semantics so that
/// `echo "secret" | icloud-keychain set ... -` behaves intuitively. Use
/// `printf 'secret' | ...` when the secret must be byte-exact.
fn readStdinPassword(allocator: std.mem.Allocator) ![]u8 {
    var buf: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&buf);
    const data = try stdin_reader.interface.allocRemaining(allocator, .limited(stdin_max_size));
    if (data.len > 0 and data[data.len - 1] == '\n') {
        const trim: usize = if (data.len >= 2 and data[data.len - 2] == '\r') 2 else 1;
        const trimmed = try allocator.dupe(u8, data[0 .. data.len - trim]);
        allocator.free(data);
        return trimmed;
    }
    return data;
}

fn usage() noreturn {
    std.debug.print(
        \\Usage:
        \\  icloud-keychain set [--sync] <service> <account> <password|->
        \\  icloud-keychain get <service> <account>
        \\  icloud-keychain delete <service> <account>
        \\  icloud-keychain list [service-filter]
        \\
        \\Options:
        \\  --sync    Enable iCloud Keychain sync (requires entitlements)
        \\            Without --sync, secrets are stored in the local login keychain.
        \\
        \\Pass `-` as the password to read it from stdin. A single trailing newline
        \\is stripped, so `echo "secret" | icloud-keychain set ... -` works. Use
        \\`printf 'secret' | ...` when the secret must be byte-exact.
        \\
    , .{});
    std.process.exit(1);
}
