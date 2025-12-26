const std = @import("std");
const builtin = @import("builtin");
const log = @import("log");
const hexdump = @import("hexdump");
const parse = @import("parse");
const git = @import("git.zig");
const toml = @import("fusefsc_toml.zig");
const fuse = @import("fusefsc_fuse.zig");
const net = std.net;
const posix = std.posix;

var g_allocator: std.mem.Allocator = std.heap.c_allocator;
var g_term: [2]i32 = .{-1, -1};
var g_deamonize: bool = false;
var g_config_file: [128:0]u8 =
        .{'f', 'u', 's', 'e', 'f', 's', 'c', '.', 't', 'o', 'm', 'l'} ++
        .{0} ** 116;

pub const fusefsc_info_t = struct // just one of these
{
    //*************************************************************************
    fn init(self: *fusefsc_info_t) !void
    {
        self.* = .{};
    }

    //*************************************************************************
    fn deinit(self: *fusefsc_info_t) void
    {
        _ = self;
    }

};

//*****************************************************************************
export fn term_sig(_: c_int) void
{
    const msg: [4]u8 = .{'i', 'n', 't', 0};
    _ = posix.write(g_term[1], msg[0..4]) catch return;
}

//*****************************************************************************
export fn pipe_sig(_: c_int) void
{
}

//*****************************************************************************
fn setup_signals() !void
{
    g_term = try posix.pipe();
    var sa: posix.Sigaction = undefined;
    sa.mask =
    if ((builtin.zig_version.major == 0) and (builtin.zig_version.minor < 15))
            posix.empty_sigset else posix.sigemptyset();
    sa.flags = 0;
    sa.handler = .{.handler = term_sig};
    if ((builtin.zig_version.major == 0) and (builtin.zig_version.minor == 13))
    {
        try posix.sigaction(posix.SIG.INT, &sa, null);
        try posix.sigaction(posix.SIG.TERM, &sa, null);
        sa.handler = .{.handler = pipe_sig};
        try posix.sigaction(posix.SIG.PIPE, &sa, null);
    }
    else
    {
        posix.sigaction(posix.SIG.INT, &sa, null);
        posix.sigaction(posix.SIG.TERM, &sa, null);
        sa.handler = .{.handler = pipe_sig};
        posix.sigaction(posix.SIG.PIPE, &sa, null);
    }
}

//*****************************************************************************
fn cleanup_signals() void
{
    posix.close(g_term[0]);
    posix.close(g_term[1]);
}

//*****************************************************************************
pub fn main() !void
{
    try log.init(&g_allocator, log.LogLevel.debug);
    defer log.deinit();
    try setup_signals();
    defer cleanup_signals();
    try log.logln(log.LogLevel.info, @src(), "signals init ok", .{});
    // setup fusefsc_info
    var fusefsc_info: fusefsc_info_t = undefined;
    try fusefsc_info.init();
    defer fusefsc_info.deinit();
    const config_file = std.mem.sliceTo(&g_config_file, 0);
    try toml.setup_fusefsc_info(&g_allocator, &fusefsc_info, config_file);
}
