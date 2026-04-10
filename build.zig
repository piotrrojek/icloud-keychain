const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "icloud-keychain",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // Link macOS frameworks required for Keychain access.
    // Security.framework provides SecItemAdd, SecItemCopyMatching, SecItemDelete.
    // CoreFoundation.framework provides CFDictionary, CFString, CFData, etc.
    exe.root_module.linkFramework("Security", .{});
    exe.root_module.linkFramework("CoreFoundation", .{});

    b.installArtifact(exe);

    // `zig build run -- set myservice myaccount mypassword`
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const test_step = b.step("test", "Run unit tests");
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);
}
