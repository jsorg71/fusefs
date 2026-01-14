const std = @import("std");
const builtin = @import("builtin");
const log = @import("log");
const hexdump = @import("hexdump");
const parse = @import("parse");
const git = @import("git.zig");
const toml = @import("fusefss_toml.zig");
const structs = @import("fusefss_structs.zig");
const net = std.net;
const posix = std.posix;

var g_allocator: std.mem.Allocator = std.heap.c_allocator;
var g_term: [2]i32 = .{-1, -1};
var g_deamonize: bool = false;
var g_config_file: [128:0]u8 =
        .{'f', 'u', 's', 'e', 'f', 's', 's', '.', 't', 'o', 'm', 'l'} ++
        .{0} ** 116;

const g_hello_str = "Hello World!\n";
const g_hello_name = "hello";
//const g_hello_name = "autorun.inf";

pub const FusefssError = error
{
    TermSet,
    ShowCommandLine,
    TooManyFds,
    MsgTooBig,
};

const sout_info_t = struct
{
    out_data_slice: [64 * 1024]u8 = undefined,
    msg_size: usize = 0,
    sent: usize = 0,
    next: ?*sout_info_t = null,

    //*************************************************************************
    fn init(self: *sout_info_t) !void
    {
        self.* = .{};
    }

    //*************************************************************************
    fn deinit(self: *sout_info_t) void
    {
        _ = self;
    }

};

const peer_info_t = struct
{
    sck: i32 = -1,
    delme: bool = false,
    sout_head: ?*sout_info_t = null,
    sout_tail: ?*sout_info_t = null,
    poll_index: usize = 0xFFFFFFFF,
    in_data_slice: [64 * 1024]u8 = undefined,
    msg_size: usize = 0,
    readed: usize = 0,
    next: ?*peer_info_t = null,

    //*************************************************************************
    fn init(self: *peer_info_t) !void
    {
        self.* = .{};
    }

    //*************************************************************************
    fn deinit(self: *peer_info_t) void
    {
        while (self.sout_head) |asout|
        {
            self.sout_head = asout.next;
            if (self.sout_head == null)
            {
                self.sout_tail = null;
            }
            asout.deinit();
            g_allocator.destroy(asout);
        }
    }

    //*************************************************************************
    fn append_sout(self: *peer_info_t, sout_info: *sout_info_t) !void
    {
        if (self.sout_tail) |asout_info|
        {
            asout_info.next = sout_info;
            self.sout_tail = sout_info;
        }
        else
        {
            self.sout_head = sout_info;
            self.sout_tail = sout_info;
        }
    }

    //*************************************************************************
    fn send_reply_attr(self: *peer_info_t, req: u64, mstat: *structs.MyStat,-
            attr_timeout: f64) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        const sout_info = try g_allocator.create(sout_info_t);
        errdefer g_allocator.destroy(sout_info);
        try sout_info.init();
        errdefer sout_info.deinit();
        const sout = try parse.parse_t.create_from_slice(&g_allocator,
                &sout_info.out_data_slice);
        defer sout.delete();
        try sout.check_rem(4);
        sout.push_layer(4, 0);
        try sout.check_rem(8);
        sout.out_u64_le(req);
        try mstat.out(sout);
        try sout.check_rem(8);
        sout.out_f64_le(attr_timeout);
        sout.push_layer(0, 1);
        const out_size = sout.layer_subtract(1, 0);
        sout.pop_layer(0);
        sout.out_u16_le(2);
        sout.out_u16_le(out_size);
        sout_info.msg_size = out_size;
        try self.append_sout(sout_info);
    }

    //*************************************************************************
    fn send_reply_entry(self: *peer_info_t, req: u64, ep: *structs.MyEntryParam) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        const sout_info = try g_allocator.create(sout_info_t);
        errdefer g_allocator.destroy(sout_info);
        try sout_info.init();
        errdefer sout_info.deinit();
        const sout = try parse.parse_t.create_from_slice(&g_allocator,
                &sout_info.out_data_slice);
        defer sout.delete();
        try sout.check_rem(4);
        sout.push_layer(4, 0);
        try sout.check_rem(8);
        sout.out_u64_le(req);
        try ep.out(sout);
        sout.push_layer(0, 1);
        const out_size = sout.layer_subtract(1, 0);
        sout.pop_layer(0);
        sout.out_u16_le(9);
        sout.out_u16_le(out_size);
        sout_info.msg_size = out_size;
        try self.append_sout(sout_info);
    }

    //*************************************************************************
    fn send_reply_err(self: *peer_info_t, req: u64, ierr: i32) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        const sout_info = try g_allocator.create(sout_info_t);
        errdefer g_allocator.destroy(sout_info);
        try sout_info.init();
        errdefer sout_info.deinit();
        const sout = try parse.parse_t.create_from_slice(&g_allocator,
                &sout_info.out_data_slice);
        defer sout.delete();
        try sout.check_rem(4);
        sout.push_layer(4, 0);
        try sout.check_rem(8 + 4);
        sout.out_u64_le(req);
        sout.out_i32_le(ierr);
        sout.push_layer(0, 1);
        const out_size = sout.layer_subtract(1, 0);
        sout.pop_layer(0);
        sout.out_u16_le(10);
        sout.out_u16_le(out_size);
        sout_info.msg_size = out_size;
        try self.append_sout(sout_info);
    }

//        var fi: structs.MyFileInfo = .{};
//        try fi.in(sin);

    //*************************************************************************
    fn process_lookup(self: *peer_info_t, code: u16, size: u16,
            sin: *parse.parse_t) !void
    {
        try sin.check_rem(8 + 8 + 2);
        const req = sin.in_u64_le();
        const parent = sin.in_u64_le();
        const name_len = sin.in_u16_le();
        try sin.check_rem(name_len);
        const name_slice = sin.in_u8_slice(name_len);
        try log.logln(log.LogLevel.info, @src(),
                "code {} size {} parent [{}] name [{s}]",
                .{code, size, parent, name_slice});
        if (parent != 1 or !std.mem.eql(u8, name_slice, g_hello_name))
        {
            try self.send_reply_err(req, 2); // ENOENT
        }
        else
        {
            var ep: structs.MyEntryParam = .{};
            ep.ino = 2;
            ep.attr_timeout = 1.0;
            ep.entry_timeout = 1.0;
            ep.attr.st_mode = 0o0100000 | 0o0444; // S_IFREG
            ep.attr.st_nlink = 1;
            ep.attr.st_size = g_hello_str.len;
            try self.send_reply_entry(req, &ep);
        }
    }

    //*************************************************************************
    fn process_getattr(self: *peer_info_t, code: u16, size: u16,
            sin: *parse.parse_t) !void
    {
        try sin.check_rem(8 + 8 + 1);
        const req = sin.in_u64_le();
        const ino = sin.in_u64_le();
        const got_fi = sin.in_u8();
        var fi: structs.MyFileInfo = .{};
        if (got_fi != 0)
        {
            try fi.in(sin);
        }
        try log.logln(log.LogLevel.info, @src(),
                "code {} size {} req 0x{X} ino 0x{X} flags 0x{X} " ++
                "padding 0x{X} fh 0x{X}",
                .{code, size, req, ino, fi.flags, fi.padding, fi.fh});
        
        if (ino != 0 and ino != 1)
        {
            try self.send_reply_err(req, 2); // ENOENT
        }
        else
        {
            var stat: structs.MyStat = .{};
            stat.st_ino = ino;
            if (ino == 1)
            {
                stat.st_mode = 0o0040000 | 0o0755; // S_IFDIR | 0755;
                stat.st_nlink = 2;
            }
            else if (ino == 2)
            {
                stat.st_mode = 0o0100000 | 0o0444; // S_IFREG | 0444;
                stat.st_nlink = 2;
                stat.st_size = g_hello_str.len;
            }
            try self.send_reply_attr(req, &stat, 1.0);
        }
    }

    //*************************************************************************
    fn process_opendir(self: *peer_info_t, code: u16, size: u16,
            sin: *parse.parse_t) !void
    {
        try sin.check_rem(8 + 8);
        const req = sin.in_u64_le();
        const ino = sin.in_u64_le();
        const got_fi = sin.in_u8();
        var fi: structs.MyFileInfo = .{};
        if (got_fi != 0)
        {
            try fi.in(sin);
        }
        try log.logln(log.LogLevel.info, @src(),
                "code {} size {} req 0x{X} ino 0x{X} flags 0x{X} " ++
                "padding 0x{X} fh 0x{X}",
                .{code, size, req, ino, fi.flags, fi.padding, fi.fh});
        try self.send_reply_err(req, 2); // ENOENT
    }

    //*************************************************************************
    fn process_other(self: *peer_info_t, code: u16, size: u16,
            sin: *parse.parse_t) !void
    {
        _ = self;
        _ = sin;
        try log.logln(log.LogLevel.info, @src(),
                "code {} size {}", .{code, size});
    }

    //*************************************************************************
    fn process_msg(self: *peer_info_t) !void
    {
        const sin = try parse.parse_t.create_from_slice(&g_allocator,
                self.in_data_slice[0..self.msg_size]);
        defer sin.delete();
        try sin.check_rem(4);
        const code = sin.in_u16_le();
        const size = sin.in_u16_le();
        try switch (code)
        {
            1 => self.process_lookup(code, size, sin),
            13 => self.process_getattr(code, size, sin),
            15 => self.process_opendir(code, size, sin),
            else => self.process_other(code, size, sin),
        };
    }

};

pub const fusefss_info_t = struct // just one of these
{
    sck: i32 = -1, // listener
    peer_head: ?*peer_info_t = null,
    peer_tail: ?*peer_info_t = null,

    //*************************************************************************
    fn init(self: *fusefss_info_t) !void
    {
        self.* = .{};
    }

    //*************************************************************************
    fn deinit(self: *fusefss_info_t) void
    {
        if (self.sck != -1)
        {
            posix.close(self.sck);
        }
        while (self.peer_head) |apeer|
        {
            self.peer_head = apeer.next;
            if (self.peer_head == null)
            {
                self.peer_tail = null;
            }
            apeer.deinit();
            g_allocator.destroy(apeer);
        }
    }

    //*************************************************************************
    fn print_fusefss_info(self: *fusefss_info_t) !void
    {
        _ = self;
    }

    //*************************************************************************
    // put peer fds in poll array
    fn peers_to_polls(self: *fusefss_info_t, polls: []posix.pollfd,
            apoll_count: usize, max_polls: usize) !usize
    {
        var poll_count = apoll_count;
        var peer: ?*peer_info_t = self.peer_head;
        while (peer) |apeer|
        {
            if (poll_count >= max_polls)
            {
                return FusefssError.TooManyFds;
            }
            //try log.logln(log.LogLevel.info, @src(),
            //        "adding IN", .{});
            apeer.poll_index = poll_count;
            polls[poll_count].fd = apeer.sck;
            polls[poll_count].events = posix.POLL.IN;
            polls[poll_count].revents = 0;
            if (apeer.sout_head != null)
            {
                //try log.logln(log.LogLevel.info, @src(),
                //        "adding OUT", .{});
                polls[poll_count].events |= posix.POLL.OUT;
            }
            poll_count += 1;
            peer = apeer.next;
        }
        return poll_count;
    }

    //*************************************************************************
    fn new_peer_in(self: *fusefss_info_t) !void
    {
        const in_sck = try posix.accept(self.sck, null, null, 0);
        if (in_sck != -1)
        {
            const new_peer = try g_allocator.create(peer_info_t);
            errdefer g_allocator.destroy(new_peer);
            try new_peer.init();
            try log.logln(log.LogLevel.info, @src(),
                    "peer in", .{});
            new_peer.sck = in_sck;
            if (self.peer_tail) |apeer_tail|
            {
                apeer_tail.next = new_peer;
                self.peer_tail = new_peer;
            }
            else
            {
                self.peer_head = new_peer;
                self.peer_tail = new_peer;
            }
        }
    }

    //*************************************************************************
    // after loop poll. check peers for in or out
    fn check_peers(self: *fusefss_info_t, active_polls: []posix.pollfd,
            poll_count: usize) !void
    {
        var peer: ?*peer_info_t = self.peer_head;
        while (peer) |apeer| : (peer = apeer.next)
        {
            //try log.logln(log.LogLevel.info, @src(),
            //        "apeer.poll_index 0x{X}", .{apeer.poll_index});
            if (apeer.poll_index >= poll_count)
            {
                continue;
            }
            const rev = active_polls[apeer.poll_index].revents;
            if ((rev & posix.POLL.IN) != 0)
            {
                const in_slice = if (apeer.readed < 4)
                        apeer.in_data_slice[apeer.readed..4] else
                        apeer.in_data_slice[apeer.readed..apeer.msg_size];
                const read = posix.recv(apeer.sck, in_slice, 0) catch 0;
                //try log.logln(log.LogLevel.info, @src(),
                //        "data in read {}", .{read});
                if (read < 1)
                {
                    apeer.delme = true;
                    continue;
                }
                apeer.readed += read;
                if (apeer.readed == 4)
                {
                    const s = try parse.parse_t.create_from_slice(
                            &g_allocator, apeer.in_data_slice[0..4]);
                    defer s.delete();
                    try s.check_rem(4);
                    s.in_u8_skip(2); // code
                    apeer.msg_size = s.in_u16_le();
                    //try log.logln(log.LogLevel.info, @src(),
                    //        "data in got header msg_size {}",
                    //        .{apeer.msg_size});
                    if (apeer.msg_size > apeer.in_data_slice.len)
                    {
                        // bad message
                        apeer.delme = true;
                        continue;
                    }
                }
                else if (apeer.readed == apeer.msg_size)
                {
                    // process message
                    try apeer.process_msg();
                    //try log.logln(log.LogLevel.info, @src(),
                    //        "data in got body msg_size {}",
                    //        .{apeer.msg_size});
                    apeer.readed = 0;
                }
            }
            if ((rev & posix.POLL.OUT) != 0)
            {
                //try log.logln(log.LogLevel.info, @src(),
                //        "data out", .{});
                if (apeer.sout_head) |asout|
                {
                    //try log.logln(log.LogLevel.info, @src(),
                    //        "data out asout.sent {} asout.msg_size {}",
                    //        .{asout.sent, asout.msg_size});
                    const out_slice =
                            asout.out_data_slice[asout.sent..asout.msg_size];
                    const sent = posix.send(apeer.sck, out_slice, 0) catch 0;
                    //try log.logln(log.LogLevel.info, @src(),
                    //        "data out sent {}", .{sent});
                    if (sent < 1)
                    {
                        apeer.delme = true;
                        continue;
                    }
                    asout.sent += sent;
                    if (asout.sent >= asout.msg_size)
                    {
                        apeer.sout_head = asout.next;
                        if (apeer.sout_head == null)
                        {
                            // if send_head is null, set send_tail to null
                            apeer.sout_tail = null;
                        }
                        asout.deinit();
                        g_allocator.destroy(asout);
                    }
                }
            }
        }
    }

    //*************************************************************************
    // at end of loop, check for peers that need to be removed
    fn remove_bad_peers(self: *fusefss_info_t) !void
    {
        var last_peer: ?*peer_info_t = null;
        var peer: ?*peer_info_t = self.peer_head;
        while (peer) |apeer|
        {
            if (apeer.delme)
            {
                // remove item from linked list
                if (last_peer) |alast_peer|
                {
                    alast_peer.next = apeer.next;
                }
                if (self.peer_head == apeer)
                {
                    self.peer_head = apeer.next;
                }
                if (self.peer_tail == apeer)
                {
                    self.peer_tail = last_peer;
                }
                // update peer, leave last_peer
                peer = apeer.next;
                // delete peer
                try log.logln(log.LogLevel.info, @src(), "peer out", .{});
                apeer.deinit();
                g_allocator.destroy(apeer);
            }
            else
            {
                // update last_peer and peer
                last_peer = apeer;
                peer = apeer.next;
            }
        }
    }

    //*************************************************************************
    fn fusefss_main_loop(self: *fusefss_info_t) !void
    {
        // start listener
        const address = net.Address.initIp4([4]u8{ 127, 0, 0, 1 }, 5055);
        const tpe: u32 = posix.SOCK.STREAM;
        self.sck = try posix.socket(address.any.family, tpe, 0);
        defer posix.close(self.sck);
        // SO_REUSEADDR
        try posix.setsockopt(self.sck,
                posix.SOL.SOCKET,
                posix.SO.REUSEADDR,
                &std.mem.toBytes(@as(c_int, 1)));
        const address_len = address.getOsSockLen();
        try posix.bind(self.sck, &address.any, address_len);
        try posix.listen(self.sck, 2);
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
            // listener
            const listen_index = poll_count;
            polls[poll_count].fd = self.sck;
            polls[poll_count].events = posix.POLL.IN;
            polls[poll_count].revents = 0;
            poll_count += 1;
            // peers
            poll_count = try self.peers_to_polls(&polls, poll_count,
                    max_polls);
            // poll
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
                if ((active_polls[listen_index].revents & posix.POLL.IN) != 0)
                {
                    try self.new_peer_in();
                }
                try self.check_peers(active_polls, poll_count);
            }
            // remove bad / disconnected peers
            try self.remove_bad_peers();
        }
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
    try writer.print("{s} - A fuse network filesystem server\n", .{app_name});
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
        return FusefssError.ShowCommandLine;
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
        if (err == FusefssError.ShowCommandLine)
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
    // setup fusefss_info
    var fusefss_info: *fusefss_info_t = try g_allocator.create(fusefss_info_t);
    defer g_allocator.destroy(fusefss_info);
    try fusefss_info.init();
    defer fusefss_info.deinit();
    const config_file = std.mem.sliceTo(&g_config_file, 0);
    try toml.setup_fusefss_info(&g_allocator, fusefss_info, config_file);
    try fusefss_info.print_fusefss_info();
    try fusefss_info.fusefss_main_loop();
}
