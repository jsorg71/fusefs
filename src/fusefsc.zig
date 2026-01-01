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

pub const FusefscError = error
{
    TermSet,
    ShowCommandLine,
};

//*****************************************************************************
inline fn err_if(b: bool, err: FusefscError) !void
{
    if (b) return err else return;
}

pub const fusefsc_info_t = struct // just one of these
{
    fu: fuse.fuse_session_t = undefined,

    //*************************************************************************
    fn init(self: *fusefsc_info_t) !void
    {
        self.* = .{};
        try self.fu.init();
    }

    //*************************************************************************
    fn deinit(self: *fusefsc_info_t) void
    {
        self.fu.deinit();
        //_ = self;
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
    if ((builtin.zig_version.major == 0) and (builtin.zig_version.minor < 14))
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
fn print_fusefsc_info(info: *fusefsc_info_t) !void
{
    _ = info;
}

//*****************************************************************************
fn fusefsc_main_loop(info: *fusefsc_info_t) !void
{
    //_ = info;
    const max_polls = 32;
    var timeout: i32 = undefined;
    var polls: [max_polls]posix.pollfd = undefined;
    var poll_count: usize = undefined;
    while (true)
    {
        timeout = -1;
        try log.logln_devel(log.LogLevel.info, @src(),
                "timeout {}", .{timeout});
        // setup poll
        poll_count = 0;
        // setup terminate fd
        const term_index = poll_count;
        polls[poll_count].fd = g_term[0];
        polls[poll_count].events = posix.POLL.IN;
        polls[poll_count].revents = 0;
        poll_count += 1;
        var rfds: [8]i32 = undefined;
        var wfds: [8]i32 = undefined;
        var num_rfds: usize = 0;
        var num_wfds: usize = 0;
        try info.fu.get_fds(&rfds, &num_rfds, &wfds, &num_wfds, &timeout);
        for (0..num_rfds) |index|
        {
            polls[poll_count].fd = rfds[index];
            polls[poll_count].events = posix.POLL.IN;
            polls[poll_count].revents = 0;
            poll_count += 1;
        }
        for (0..num_wfds) |index|
        {
            polls[poll_count].fd = wfds[index];
            polls[poll_count].events = posix.POLL.OUT;
            polls[poll_count].revents = 0;
            poll_count += 1;
        }
        const active_polls = polls[0..poll_count];
        const poll_rv = try posix.poll(active_polls, timeout);
        if (poll_rv > 0)
        {
            if ((active_polls[term_index].revents & posix.POLL.IN) != 0)
            {
                try log.logln(log.LogLevel.info, @src(), "{s}",
                        .{"term set shutting down"});
                break;
            }
        }
        try info.fu.check_fds();
    }
}

//*****************************************************************************
fn show_command_line_args() !void
{
    if ((builtin.zig_version.major == 0) and
        (builtin.zig_version.minor < 15))
    {
        const stdout = std.io.getStdOut();
        const writer = stdout.writer();
        try show_command_line_args1(writer);
    }
    else
    {
        var buf: [1024]u8 = undefined;
        const stdout = std.fs.File.stdout();
        var stdout_writer = stdout.writer(&buf);
        const writer = &stdout_writer.interface;
        try show_command_line_args1(writer);
        try writer.flush();
    }
}

//*****************************************************************************
fn show_command_line_args1(writer: anytype) !void
{
    const app_name = std.mem.sliceTo(std.os.argv[0], 0);
    const vstr = builtin.zig_version_string;
    try writer.print("{s} - A fuse network filesystem client\n", .{app_name});
    try writer.print("built with zig version {s}\n", .{vstr});
    try writer.print("git sha1 {s}\n", .{git.g_git_sha1});
    try writer.print("Usage: {s} [options]\n", .{app_name});
    try writer.print("  -h: print this help\n", .{});
    try writer.print("  -F: run in foreground\n", .{});
    try writer.print("  -D: run in background\n", .{});
}

//*****************************************************************************
fn process_args() !void
{
    var slice_arg: []u8 = undefined;
    var index: usize = 1;
    const count = std.os.argv.len;
    if (count < 2)
    {
        return FusefscError.ShowCommandLine;
    }
    while (index < count) : (index += 1)
    {
        slice_arg = std.mem.sliceTo(std.os.argv[index], 0);
        if (std.mem.eql(u8, slice_arg, "-h"))
        {
            return error.ShowCommandLine;
        }
        else if (std.mem.eql(u8, slice_arg, "-D"))
        {
            g_deamonize = true;
        }
        else if (std.mem.eql(u8, slice_arg, "-F"))
        {
            g_deamonize = false;
        }
        else if (std.mem.eql(u8, slice_arg, "-c"))
        {
            index += 1;
            if (index < count)
            {
                const slice_arg1 = std.mem.sliceTo(std.os.argv[index], 0);
                if (slice_arg1.len < g_config_file.len)
                {
                    @memset(&g_config_file, 0);
                    std.mem.copyForwards(u8, &g_config_file, slice_arg1);
                    continue;
                }
            }
            return error.ShowCommandLine;
        }
        else
        {
            return error.ShowCommandLine;
        }
    }
}

//*****************************************************************************
pub fn main() !void
{
    const result = process_args();
    if (result) |_| { } else |err|
    {
        if (err == FusefscError.ShowCommandLine)
        {
            try show_command_line_args();
        }
        return err;
    }
    if (g_deamonize)
    {
        const rv = try posix.fork();
        if (rv == 0)
        { // child
            posix.close(0);
            posix.close(1);
            posix.close(2);
            _ = try posix.open("/dev/null", .{.ACCMODE = .RDONLY}, 0);
            _ = try posix.open("/dev/null", .{.ACCMODE = .WRONLY}, 0);
            _ = try posix.open("/dev/null", .{.ACCMODE = .WRONLY}, 0);
            try log.initWithFile(&g_allocator, log.LogLevel.debug,
                    "/tmp/tty_reader.log");
        }
        else if (rv > 0)
        { // parent
            std.debug.print("started with pid {}\n", .{rv});
            return;
        }
    }
    else
    {
        try log.init(&g_allocator, log.LogLevel.debug);
    }
    defer log.deinit();
    try setup_signals();
    defer cleanup_signals();
    try log.logln(log.LogLevel.info, @src(), "signals init ok", .{});
    // setup fusefsc_info
    var fusefsc_info: *fusefsc_info_t = try g_allocator.create(fusefsc_info_t);
    defer g_allocator.destroy(fusefsc_info);
    try fusefsc_info.init();
    defer fusefsc_info.deinit();
    const config_file = std.mem.sliceTo(&g_config_file, 0);
    try toml.setup_fusefsc_info(&g_allocator, fusefsc_info, config_file);
    try print_fusefsc_info(fusefsc_info);
    try fusefsc_main_loop(fusefsc_info);
}
