const std = @import("std");
const builtin = @import("builtin");

const supported_zig = std.SemanticVersion{ .major = 0, .minor = 15, .patch = 2 };
const macos_min = std.SemanticVersion{ .major = 13, .minor = 0, .patch = 0 };
const pkg_version: []const u8 = @import("build.zig.zon").version;

comptime {
    if (builtin.zig_version.order(supported_zig) != .eq) {
        @compileError(std.fmt.comptimePrint(
            "icloud-keychain requires Zig 0.15.2 exactly (found {d}.{d}.{d}). See .zig-version.",
            .{ builtin.zig_version.major, builtin.zig_version.minor, builtin.zig_version.patch },
        ));
    }
}

pub fn build(b: *std.Build) void {
    // --sysroot is an SDK *input*. Do not leave it set: combining it with
    // SDK-prefixed -L/-F double-prefixes linker search paths.
    const sysroot_arg = b.sysroot;
    b.sysroot = null;

    const query = enforceMacos(b, b.standardTargetOptionsQueryOnly(.{}));
    const target = b.resolveTargetQuery(query);
    const optimize = b.standardOptimizeOption(.{});
    const sdk = resolveAndCheckSdk(b, target, sysroot_arg);

    const options = b.addOptions();
    options.addOption([]const u8, "version", pkg_version);

    const exe_mod = createAppModule(b, b.path("src/main.zig"), target, optimize, options, sdk);
    const exe = b.addExecutable(.{
        .name = "icloud-keychain",
        .root_module = exe_mod,
        .version = std.SemanticVersion.parse(pkg_version) catch @panic("invalid .version in build.zig.zon"),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_mod = createAppModule(b, b.path("src/tests.zig"), target, optimize, options, sdk);
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&exe.step);
}

fn createAppModule(
    b: *std.Build,
    root: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    options: *std.Build.Step.Options,
    sdk: []const u8,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = root,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addOptions("build_options", options);
    mod.linkFramework("Security", .{});
    mod.linkFramework("CoreFoundation", .{});
    applyMacSdk(b, mod, sdk);
    return mod;
}

fn enforceMacos(b: *std.Build, query: std.Target.Query) std.Target.Query {
    var q = query;
    const os_tag = q.os_tag orelse b.graph.host.result.os.tag;
    if (os_tag != .macos) {
        std.debug.print(
            "error: icloud-keychain is macOS-only; Linux and other targets are out of scope (requested {s})\n",
            .{@tagName(os_tag)},
        );
        std.process.exit(1);
    }
    q.os_tag = .macos;
    if (q.os_version_min) |min| {
        switch (min) {
            .semver => |v| if (v.order(macos_min) == .lt) {
                q.os_version_min = .{ .semver = macos_min };
            },
            else => q.os_version_min = .{ .semver = macos_min },
        }
    } else {
        q.os_version_min = .{ .semver = macos_min };
    }
    return q;
}

fn resolveAndCheckSdk(b: *std.Build, target: std.Build.ResolvedTarget, sysroot_arg: ?[]const u8) []const u8 {
    const sdk_opt = b.option([]const u8, "sdk", "Compatible macOS SDK path (overrides SDKROOT and --sysroot)");
    const detected = if (comptime builtin.zig_version.order(supported_zig) == .eq)
        std.zig.system.darwin.getSdk(b.allocator, &target.result)
    else
        null;
    const sdk = sdk_opt orelse sysroot_arg orelse envSdk() orelse detected orelse {
        std.debug.print(
            "error: macOS SDK not found. Set SDKROOT or -Dsdk=/path/to/MacOSX.sdk (or --sysroot).\n",
            .{},
        );
        std.process.exit(1);
    };

    std.fs.accessAbsolute(sdk, .{}) catch {
        std.debug.print("error: SDK path does not exist: {s}\n", .{sdk});
        std.process.exit(1);
    };

    const needle = switch (target.result.cpu.arch) {
        .aarch64 => "arm64-macos",
        .x86_64 => "x86_64-macos",
        else => {
            std.debug.print("error: unsupported macOS arch {s}\n", .{@tagName(target.result.cpu.arch)});
            std.process.exit(1);
        },
    };
    if (!securityTbdHas(sdk, needle)) {
        std.debug.print(
            "error: SDK {s} is incompatible with Zig 0.15.2 (Security.framework TBD has no {s}).\n" ++
                "Select a compatible application SDK with SDKROOT or -Dsdk= (for example MacOSX15.4.sdk).\n" ++
                "If Zig's build runner cannot link, select a compatible developer installation per command; see README.md.\n",
            .{ sdk, needle },
        );
        std.process.exit(1);
    }
    return sdk;
}

fn envSdk() ?[]const u8 {
    const value = std.posix.getenv("SDKROOT") orelse return null;
    if (value.len == 0) return null;
    return value;
}

fn securityTbdHas(sdk: []const u8, needle: []const u8) bool {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/System/Library/Frameworks/Security.framework/Security.tbd", .{sdk}) catch return false;
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();
    var buf: [8192]u8 = undefined;
    const n = file.read(&buf) catch return false;
    return std.mem.indexOf(u8, buf[0..n], needle) != null;
}

fn applyMacSdk(b: *std.Build, mod: *std.Build.Module, sdk: []const u8) void {
    // Match the known-good clang/zig test line: -F -I -L against the SDK, no --sysroot.
    mod.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }) });
    mod.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }) });
    mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr/lib" }) });
}
