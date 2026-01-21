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

var g_hello_fd: [256]u8 = undefined;
var g_hello1_fd: [256]u8 = undefined;

//const g_hello_filedata = "Hello World!" ++
//        "  This is a test of the emergency broadcasting system." ++
//        "  This is only a test.\n";

var g_hello_filedata: []u8 = g_hello_fd[0..0];
const g_hello_filename = "hello";

//const g_hello1_filedata = "Hello1 World!" ++
//        "  This is a test of the emergency broadcasting system." ++
//        "  This is only a test.\n";

var g_hello1_filedata: []u8 = g_hello1_fd[0..0];
const g_hello1_filename = "hello1";

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
        if (self.sck != -1)
        {
            posix.close(self.sck);
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
    fn send_reply_attr(self: *peer_info_t, req: u64, mstat: *structs.MyStat,
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
        const code = @intFromEnum(structs.MyFuseReplyMsg.attr);
        sout.out_u16_le(code);
        sout.out_u16_le(out_size);
        sout_info.msg_size = out_size;
        try self.append_sout(sout_info);
    }

    //*************************************************************************
    fn send_reply_write(self: *peer_info_t, req: u64, count: u64) !void
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
        try sout.check_rem(8 + 8);
        sout.out_u64_le(req);
        sout.out_u64_le(count);
        sout.push_layer(0, 1);
        const out_size = sout.layer_subtract(1, 0);
        sout.pop_layer(0);
        const code = @intFromEnum(structs.MyFuseReplyMsg.write);
        sout.out_u16_le(code);
        sout.out_u16_le(out_size);
        sout_info.msg_size = out_size;
        try self.append_sout(sout_info);
    }

    //*************************************************************************
    fn send_reply_buf(self: *peer_info_t, req: u64, buf: []const u8) !void
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
        try sout.check_rem(8 + 2 + buf.len);
        sout.out_u64_le(req);
        sout.out_u16_le(@intCast(buf.len));
        sout.out_u8_slice(buf);
        sout.push_layer(0, 1);
        const out_size = sout.layer_subtract(1, 0);
        sout.pop_layer(0);
        const code = @intFromEnum(structs.MyFuseReplyMsg.buf);
        sout.out_u16_le(code);
        sout.out_u16_le(out_size);
        sout_info.msg_size = out_size;
        try self.append_sout(sout_info);
    }

    //*************************************************************************
    fn send_reply_buf_dir(self: *peer_info_t, req: u64, size: u64, off: i64,
            dir_items: []structs.dir_item) !void
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
        try sout.check_rem(3 * 8 + 2);
        sout.out_u64_le(req);
        sout.out_u64_le(size);
        sout.out_i64_le(off);
        sout.out_u16_le(@intCast(dir_items.len));
        for (dir_items) |dir_item|
        {
            try sout.check_rem(8 + 4 + 2);
            sout.out_u64_le(dir_item.ino);
            sout.out_u32_le(dir_item.mode);
            sout.out_u16_le(@intCast(dir_item.name.len + 1));
            try sout.check_rem(dir_item.name.len + 1);
            sout.out_u8_slice(dir_item.name);
            sout.out_u8(0);
        }
        sout.push_layer(0, 1);
        const out_size = sout.layer_subtract(1, 0);
        sout.pop_layer(0);
        const code = @intFromEnum(structs.MyFuseReplyMsg.buf_dir);
        sout.out_u16_le(code);
        sout.out_u16_le(out_size);
        sout_info.msg_size = out_size;
        try self.append_sout(sout_info);
    }

    //*************************************************************************
    fn send_reply_open(self: *peer_info_t, req: u64,
            fi: *structs.MyFileInfo) !void
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
        try fi.out(sout);
        sout.push_layer(0, 1);
        const out_size = sout.layer_subtract(1, 0);
        sout.pop_layer(0);
        const code = @intFromEnum(structs.MyFuseReplyMsg.open);
        sout.out_u16_le(code);
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
        const code = @intFromEnum(structs.MyFuseReplyMsg.entry);
        sout.out_u16_le(code);
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
        const code = @intFromEnum(structs.MyFuseReplyMsg.err);
        sout.out_u16_le(code);
        sout.out_u16_le(out_size);
        sout_info.msg_size = out_size;
        try self.append_sout(sout_info);
    }

    //*************************************************************************
    fn process_lookup(self: *peer_info_t, sin: *parse.parse_t) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        try sin.check_rem(8 + 8 + 2);
        const req = sin.in_u64_le();
        const parent = sin.in_u64_le();
        const name_len = sin.in_u16_le();
        try sin.check_rem(name_len);
        const name_slice = std.mem.sliceTo(sin.in_u8_slice(name_len), 0);
        try log.logln_devel(log.LogLevel.info, @src(),
                "parent [{}] name [{s}]",
                .{parent, name_slice});
        const is_file = std.mem.eql(u8, name_slice, g_hello_filename);
        const is_file1 = std.mem.eql(u8, name_slice, g_hello1_filename);
        if (parent == 1)
        {
            var ep: structs.MyEntryParam = .{};
            ep.attr_timeout = 1.0;
            ep.entry_timeout = 1.0;
            ep.attr.st_mode = 0o0100000 | 0o0664; // S_IFREG
            ep.attr.st_nlink = 1;
            ep.attr.st_uid = 1000;
            ep.attr.st_gid = 1000;
            // Date and time (GMT): Sunday, January 19, 2020 3:32:15 AM
            ep.attr.st_mtim_tv_sec = 1579404735;
            ep.attr.st_ctim_tv_sec = 1579404735;
            ep.attr.st_atim_tv_sec = 1579404735;
            if (is_file)
            {
                ep.ino = 2;
                ep.attr.st_size = @intCast(g_hello_filedata.len);
                try self.send_reply_entry(req, &ep);
                return;
            }
            if (is_file1)
            {
                ep.ino = 3;
                ep.attr.st_size = @intCast(g_hello1_filedata.len);
                try self.send_reply_entry(req, &ep);
                return;
            }
        }
        try self.send_reply_err(req, 2); // ENOENT
    }

    //*************************************************************************
    fn process_readdir(self: *peer_info_t, sin: *parse.parse_t) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        try sin.check_rem(4 * 8 + 1);
        const req = sin.in_u64_le();
        const ino = sin.in_u64_le();
        const size = sin.in_u64_le();
        const off = sin.in_i64_le();
        var fi: structs.MyFileInfo = .{};
        const got_fi = sin.in_u8();
        if (got_fi != 0)
        {
            try log.logln_devel(log.LogLevel.info, @src(), "fi yes", .{});
            try fi.in(sin);
        }
        else
        {
            try log.logln_devel(log.LogLevel.info, @src(), "fi no", .{});
        }
        try log.logln_devel(log.LogLevel.info, @src(),
                "req 0x{X} ino 0x{X} size {} off {}",
                .{req, ino, size, off});
        if (ino != 1)
        {
            try self.send_reply_err(req, 20); // ENOTDIR
        }
        else
        {
            var dir_items = try g_allocator.alloc(structs.dir_item, 4);
            defer g_allocator.free(dir_items);
            dir_items[0] = .{};
            dir_items[0].ino = 1;
            dir_items[0].name = ".";
            dir_items[1] = .{};
            dir_items[1].ino = 1;
            dir_items[1].name = "..";
            dir_items[2] = .{};
            dir_items[2].ino = 2;
            dir_items[2].name = g_hello_filename;
            dir_items[3] = .{};
            dir_items[3].ino = 3;
            dir_items[3].name = g_hello1_filename;
            try self.send_reply_buf_dir(req, size, off, dir_items);
        }
    }

    //*************************************************************************
    fn process_open(self: *peer_info_t, sin: *parse.parse_t) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        try sin.check_rem(8 + 8 + 1);
        const req = sin.in_u64_le();
        const ino = sin.in_u64_le();
        var fi: structs.MyFileInfo = .{};
        const got_fi = sin.in_u8();
        if (got_fi != 0)
        {
            try log.logln_devel(log.LogLevel.info, @src(), "fi yes", .{});
            try fi.in(sin);
            try log.logln(log.LogLevel.info, @src(), "flags 0x{X}", .{fi.flags});
        }
        else
        {
            try log.logln_devel(log.LogLevel.info, @src(), "fi no", .{});
        }

        if ((ino != 2) and (ino != 3))
        {
            try self.send_reply_err(req, 21); // EISDIR
        }
        // else if ((fi.flags & 3) != 0) // 0 = O_RDONLY
        // {
        //     try self.send_reply_err(req, 13); // EACCES
        // }
        else
        {
            try self.send_reply_open(req, &fi);
            if ((got_fi != 0) and ((fi.flags & 0o1000) != 0)) // O_TRUNC
            {
                if (ino == 2)
                {
                    g_hello_filedata = g_hello_fd[0..0];
                }
                else
                {
                    g_hello1_filedata = g_hello1_fd[0..0];
                }
            }
        }
    }

    //*************************************************************************
    fn process_release(self: *peer_info_t, sin: *parse.parse_t) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        try sin.check_rem(8 + 8 + 1);
        const req = sin.in_u64_le();
        const ino = sin.in_u64_le();
        var fi: structs.MyFileInfo = .{};
        const got_fi = sin.in_u8();
        if (got_fi != 0)
        {
            try log.logln_devel(log.LogLevel.info, @src(), "fi yes", .{});
            try fi.in(sin);
        }
        else
        {
            try log.logln_devel(log.LogLevel.info, @src(), "fi no", .{});
        }
        _ = self;
        _ = req;
        _ = ino;
    }

    //*************************************************************************
    fn process_read(self: *peer_info_t, sin: *parse.parse_t) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        try sin.check_rem(4 * 8 + 1);
        const req = sin.in_u64_le();
        const ino = sin.in_u64_le();
        const size = sin.in_u64_le();
        const off = sin.in_i64_le();
        var fi: structs.MyFileInfo = .{};
        const got_fi = sin.in_u8();
        if (got_fi != 0)
        {
            try log.logln_devel(log.LogLevel.info, @src(), "fi yes", .{});
            try fi.in(sin);
        }
        else
        {
            try log.logln_devel(log.LogLevel.info, @src(), "fi no", .{});
        }
        try log.logln_devel(log.LogLevel.info, @src(),
                "req 0x{X} ino 0x{X} size {} off {}",
                .{req, ino, size, off});
        if (ino != 2 and ino != 3)
        {
            try self.send_reply_err(req, 2); // ENOENT
        }
        else
        {
            if (ino == 2)
            {
                const size_usize: usize = @intCast(size);
                const off_usize: usize = @intCast(off);
                const end = @min(g_hello_filedata.len, size_usize);
                try log.logln_devel(log.LogLevel.info, @src(),
                        "off_usize 0x{X} end 0x{X}",
                        .{off_usize, end});
                try self.send_reply_buf(req, g_hello_filedata[off_usize..end]);
            }
            else
            {
                const size_usize: usize = @intCast(size);
                const off_usize: usize = @intCast(off);
                const end = @min(g_hello1_filedata.len, size_usize);
                try log.logln_devel(log.LogLevel.info, @src(),
                        "off_usize 0x{X} end 0x{X}",
                        .{off_usize, end});
                try self.send_reply_buf(req, g_hello1_filedata[off_usize..end]);
            }
        }
    }

    //*************************************************************************
    fn process_write(self: *peer_info_t, sin: *parse.parse_t) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        try sin.check_rem(3 * 8);
        const req = sin.in_u64_le();
        const ino = sin.in_u64_le();
        const size = sin.in_u64_le();
        try sin.check_rem(size);
        const buf = sin.in_u8_slice(size);
        try sin.check_rem(8 + 1);
        const off = sin.in_i64_le();
        var fi: structs.MyFileInfo = .{};
        const got_fi = sin.in_u8();
        if (got_fi != 0)
        {
            try log.logln_devel(log.LogLevel.info, @src(), "fi yes", .{});
            try fi.in(sin);
        }
        else
        {
            try log.logln_devel(log.LogLevel.info, @src(), "fi no", .{});
        }
        try log.logln_devel(log.LogLevel.info, @src(),
                "req 0x{X} ino 0x{X} size {} off {}",
                .{req, ino, size, off});
        if (ino != 2 and ino != 3)
        {
            try self.send_reply_err(req, 2); // ENOENT
        }
        else
        {
            if (ino == 2)
            {
                const dst_start: usize = @intCast(off);
                const dst_end: usize = @intCast(off + @as(i64, @intCast(size)));
                const src_end: usize = @intCast(size);
                std.mem.copyForwards(u8, g_hello_fd[dst_start..dst_end], buf[0..src_end]);
                const file_end = @max(dst_end, g_hello_filedata.len);
                g_hello_filedata = g_hello_fd[0..file_end];
                try self.send_reply_write(req, size);
            }
            else
            {
                const dst_start: usize = @intCast(off);
                const dst_end: usize = @intCast(off + @as(i64, @intCast(size)));
                const src_end: usize = @intCast(size);
                std.mem.copyForwards(u8, g_hello1_fd[dst_start..dst_end], buf[0..src_end]);
                const file_end = @max(dst_end, g_hello1_filedata.len);
                g_hello1_filedata = g_hello1_fd[0..file_end];
                try self.send_reply_write(req, size);
            }
        }
    }

    //*************************************************************************
    fn process_getattr(self: *peer_info_t, sin: *parse.parse_t) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        try sin.check_rem(8 + 8 + 1);
        const req = sin.in_u64_le();
        const ino = sin.in_u64_le();
        const got_fi = sin.in_u8();
        var fi: structs.MyFileInfo = .{};
        if (got_fi != 0)
        {
            try log.logln_devel(log.LogLevel.info, @src(), "fi yes", .{});
            try fi.in(sin);
        }
        else
        {
            try log.logln_devel(log.LogLevel.info, @src(), "fi no", .{});
        }
        try log.logln_devel(log.LogLevel.info, @src(),
                "req 0x{X} ino 0x{X} flags 0x{X} " ++
                "padding 0x{X} fh 0x{X}",
                .{req, ino, fi.flags, fi.padding, fi.fh});
        
        if ((ino != 1) and (ino != 2) and (ino != 3))
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
                stat.st_size = 4096;
                stat.st_uid = 1000;
                stat.st_gid = 1000;
                // Date and time (GMT): Sunday, January 19, 2020 3:32:15 AM
                stat.st_mtim_tv_sec = 1579404735;
                stat.st_ctim_tv_sec = 1579404735;
                stat.st_atim_tv_sec = 1579404735;
            }
            else if (ino == 2)
            {
                stat.st_mode = 0o0100000 | 0o0444; // S_IFREG | 0444;
                stat.st_nlink = 2;
                stat.st_size = @intCast(g_hello_filedata.len);
                stat.st_uid = 1000;
                stat.st_gid = 1000;
                // Date and time (GMT): Sunday, January 19, 2020 3:32:15 AM
                stat.st_mtim_tv_sec = 1579404735;
                stat.st_ctim_tv_sec = 1579404735;
                stat.st_atim_tv_sec = 1579404735;
            }
            else
            {
                stat.st_mode = 0o0100000 | 0o0444; // S_IFREG | 0444;
                stat.st_nlink = 2;
                stat.st_size = @intCast(g_hello1_filedata.len);
                stat.st_uid = 1000;
                stat.st_gid = 1000;
                // Date and time (GMT): Sunday, January 19, 2020 3:32:15 AM
                stat.st_mtim_tv_sec = 1579404735;
                stat.st_ctim_tv_sec = 1579404735;
                stat.st_atim_tv_sec = 1579404735;
            }
            try self.send_reply_attr(req, &stat, 1.0);
        }
    }

    //*************************************************************************
    fn process_opendir(self: *peer_info_t, sin: *parse.parse_t) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        try sin.check_rem(8 + 8 + 1);
        const req = sin.in_u64_le();
        const ino = sin.in_u64_le();
        const got_fi = sin.in_u8();
        var fi: structs.MyFileInfo = .{};
        if (got_fi != 0)
        {
            try log.logln_devel(log.LogLevel.info, @src(), "fi yes", .{});
            try fi.in(sin);
        }
        else
        {
            try log.logln_devel(log.LogLevel.info, @src(), "fi no", .{});
        }
        try log.logln_devel(log.LogLevel.info, @src(),
                "req 0x{X} ino 0x{X} flags 0x{X} " ++
                "padding 0x{X} fh 0x{X}",
                .{req, ino, fi.flags, fi.padding, fi.fh});
        if (ino != 1)
        {
            try self.send_reply_err(req, 20); // ENOTDIR
        }
        else
        {
            try self.send_reply_open(req, &fi);
        }
    }

    //*************************************************************************
    fn process_other(self: *peer_info_t, pdu_code: structs.MyFuseMsg) !void
    {
        _ = self;
        try log.logln(log.LogLevel.info, @src(), "pdu_code {}", .{pdu_code});
    }

    //*************************************************************************
    fn process_msg(self: *peer_info_t) !void
    {
        const sin = try parse.parse_t.create_from_slice(&g_allocator,
                self.in_data_slice[0..self.msg_size]);
        defer sin.delete();
        try sin.check_rem(4);
        const pdu_code: structs.MyFuseMsg = @enumFromInt(sin.in_u16_le());
        sin.in_u8_skip(2); // pdu_size
        try switch (pdu_code)
        {
            .lookup => self.process_lookup(sin),
            .readdir => self.process_readdir(sin),
            .open => self.process_open(sin),
            .release => self.process_release(sin),
            .read => self.process_read(sin),
            .write => self.process_write(sin),
            .getattr => self.process_getattr(sin),
            .opendir => self.process_opendir(sin),
            else => self.process_other(pdu_code),
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
        //log.logln(log.LogLevel.info, @src(),
        //            "sck {}", .{self.sck}) catch return;
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
            try log.logln_devel(log.LogLevel.info, @src(),
                    "adding IN", .{});
            apeer.poll_index = poll_count;
            polls[poll_count].fd = apeer.sck;
            polls[poll_count].events = posix.POLL.IN;
            polls[poll_count].revents = 0;
            if (apeer.sout_head != null)
            {
                try log.logln_devel(log.LogLevel.info, @src(),
                        "adding OUT", .{});
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
            try log.logln_devel(log.LogLevel.info, @src(),
                    "apeer.poll_index 0x{X}", .{apeer.poll_index});
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
                try log.logln_devel(log.LogLevel.info, @src(),
                        "data in read {}", .{read});
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
                    try log.logln_devel(log.LogLevel.info, @src(),
                            "data in got header msg_size {}",
                            .{apeer.msg_size});
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
                    try log.logln_devel(log.LogLevel.info, @src(),
                            "data in got body msg_size {}",
                            .{apeer.msg_size});
                    apeer.readed = 0;
                }
            }
            if ((rev & posix.POLL.OUT) != 0)
            {
                try log.logln_devel(log.LogLevel.info, @src(),
                        "data out", .{});
                if (apeer.sout_head) |asout|
                {
                    try log.logln_devel(log.LogLevel.info, @src(),
                            "data out asout.sent {} asout.msg_size {}",
                            .{asout.sent, asout.msg_size});
                    const out_slice =
                            asout.out_data_slice[asout.sent..asout.msg_size];
                    const sent = posix.send(apeer.sck, out_slice, 0) catch 0;
                    try log.logln_devel(log.LogLevel.info, @src(),
                            "data out sent {}", .{sent});
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
        //defer posix.close(self.sck);
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
    var fusefss_info = try g_allocator.create(fusefss_info_t);
    defer g_allocator.destroy(fusefss_info);
    try fusefss_info.init();
    defer fusefss_info.deinit();
    const config_file = std.mem.sliceTo(&g_config_file, 0);
    try toml.setup_fusefss_info(&g_allocator, fusefss_info, config_file);
    try fusefss_info.print_fusefss_info();
    try fusefss_info.fusefss_main_loop();
}
