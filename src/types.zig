const std = @import("std");

pub const Scope = enum { local, icloud, any };

pub const Entry = struct {
    service: []const u8,
    account: []const u8,
    scope: Scope,

    pub fn deinit(self: Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.service);
        allocator.free(self.account);
    }
};

pub fn freeEntries(allocator: std.mem.Allocator, entries: []Entry) void {
    for (entries) |entry| entry.deinit(allocator);
    allocator.free(entries);
}
