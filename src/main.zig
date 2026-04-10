// icloud-keychain — macOS Keychain CLI with iCloud sync.
// Copyright (c) 2026 Piotr Rojek — https://piotrrojek.io
// MIT License

const std = @import("std");
const keychain = @import("keychain.zig");

const stdout_file = std.fs.File.stdout();

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
        keychain.set(args[pos], args[pos + 1], args[pos + 2], sync) catch |err| {
            if (err == keychain.KeychainError.MissingEntitlement) {
                std.debug.print("Error: missing entitlement. iCloud sync requires a provisioned App ID.\n" ++
                    "Run without --sync to use the local keychain instead.\n", .{});
            } else {
                std.debug.print("Error: {}\n", .{err});
            }
            std.process.exit(1);
        };
        const where: []const u8 = if (sync) "iCloud Keychain" else "local Keychain";
        std.debug.print("Stored {s} / {s} in {s}.\n", .{ args[pos], args[pos + 1], where });
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

fn usage() noreturn {
    std.debug.print(
        \\Usage:
        \\  icloud-keychain set [--sync] <service> <account> <password>
        \\  icloud-keychain get <service> <account>
        \\  icloud-keychain delete <service> <account>
        \\  icloud-keychain list [service-filter]
        \\
        \\Options:
        \\  --sync    Enable iCloud Keychain sync (requires entitlements)
        \\            Without --sync, secrets are stored in the local login keychain.
        \\
    , .{});
    std.process.exit(1);
}
