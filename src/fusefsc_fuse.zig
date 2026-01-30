const std = @import("std");
const builtin = @import("builtin");
const log = @import("log");
const parse = @import("parse");
const fusefsc = @import("fusefsc.zig");
const structs = @import("fusefss_structs.zig");
const c = @cImport(
{
    @cDefine("FUSE_USE_VERSION", "35");
    @cInclude("fuse_lowlevel.h");
    @cInclude("myfuse.h");
});

var g_allocator: std.mem.Allocator = std.heap.c_allocator;

pub const FuseError = error
{
    FuseMountFailed,
    FuseNewFailed,
    FuseAllocFailed,
    FuseOtherFailed,
    BadErrorCode,
};

//*****************************************************************************
inline fn err_if(b: bool, err: FuseError) !void
{
    if (b) return err else return;
}

//*****************************************************************************
fn cb_error(src: std.builtin.SourceLocation, err: anyerror) void
{
    log.logln(log.LogLevel.info, src, "error[{}]", .{err}) catch return;
}

//*****************************************************************************
fn cb_error_int(src: std.builtin.SourceLocation, err: anyerror,
        rv: c_int) c_int
{
    log.logln(log.LogLevel.info, src, "error[{}]", .{err}) catch return rv;
    return rv;
}

const sout_info_t = struct
{
    out_data_slice: [64 * 1024]u8 = undefined,
    msg_size: usize = 0,
    sent: usize = 0,
    next: ?*sout_info_t = null,

    //*************************************************************************
    fn init(self: *sout_info_t) !void
    {
        try log.logln_devel(log.LogLevel.info, @src(),
                "sout_info_t", .{});
        self.* = .{};
    }

    //*************************************************************************
    pub fn deinit(self: *sout_info_t) void
    {
        log.logln_devel(log.LogLevel.info, @src(),
                "sout_info_t", .{}) catch return;
        _ = self;
    }

};

//*****************************************************************************
fn check_error(err: structs.MyFuseError, ierr: i32) !void
{
    const lerr = @intFromEnum(err);
    if (lerr != ierr)
    {
        try log.logln(log.LogLevel.info, @src(),
                "error code does not match for {} should be {}",
                .{err, ierr});
        return FuseError.BadErrorCode;
    }
}

//*****************************************************************************
fn mount_failed(mount_path: []const u8) anyerror
{
    try log.logln(log.LogLevel.info, @src(),
            "mount failed for path {s}", .{mount_path});
    return FuseError.FuseMountFailed;
}

pub const fuse_session_t = struct
{
    mi: ?*anyopaque = null,
    sout_head: ?*sout_info_t = null,
    sout_tail: ?*sout_info_t = null,

    //*************************************************************************
    pub fn init(self: *fuse_session_t) !void
    {
        try log.logln(log.LogLevel.info, @src(),
                "fuse_session_t", .{});
        self.* = .{};
        // make sure errors values match
        try check_error(structs.MyFuseError.ENOENT, c.ENOENT);
        try check_error(structs.MyFuseError.EACCES, c.EACCES);
        try check_error(structs.MyFuseError.ENOTDIR, c.ENOTDIR);
        try check_error(structs.MyFuseError.EISDIR, c.EISDIR);
        const mount_path = "/home/jay/test_mount";
        const rv = c.myfuse_create(mount_path, self, &self.mi);
        try log.logln(log.LogLevel.info, @src(), "myfuse_create rv {}", .{rv});
        return switch (rv)
        {
            0 => {},
            1 => FuseError.FuseAllocFailed,
            2 => FuseError.FuseNewFailed,
            3 => mount_failed(mount_path),
            else => FuseError.FuseOtherFailed,
        };
    }

    //*************************************************************************
    pub fn deinit(self: *fuse_session_t) void
    {
        log.logln(log.LogLevel.info, @src(),
                "fuse_session_t", .{}) catch return;
        _ = c.myfuse_delete(self.mi);
        // delete any not sent messages
        while (self.sout_head) |asout_info|
        {
            log.logln_devel(log.LogLevel.info, @src(), "cleanup item", .{})
                    catch return;
            self.sout_head = asout_info.next;
            //_ = c.fuse_reply_err(req, c.ENOENT);
            asout_info.deinit();
            g_allocator.destroy(asout_info);
        }
    }

    //*************************************************************************
    pub fn get_fds(self: *fuse_session_t, fd: *i32) !void
    {
        const rv = c.myfuse_get_fds(self.mi, fd);
        if (rv != 0)
        {
            try log.logln(log.LogLevel.info, @src(),
                    "myfuse_get_fds failed rv {}", .{rv});
        }
    }

    //*************************************************************************
    pub fn check_fds(self: *fuse_session_t) !void
    {
        const rv = c.myfuse_check_fds(self.mi);
        if (rv != 0)
        {
            try log.logln(log.LogLevel.info, @src(),
                    "myfuse_check_fds failed rv {}", .{rv});
        }
    }

    //*************************************************************************
    fn append_sout(self: *fuse_session_t, sout_info: *sout_info_t) !void
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
    pub fn send_version(self: *fuse_session_t) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        // create sout_info
        const sout_info = try g_allocator.create(sout_info_t);
        errdefer g_allocator.destroy(sout_info);
        try sout_info.init();
        errdefer sout_info.deinit();
        // create a temp parse
        const sout = try parse.parse_t.create_from_slice(
                &g_allocator, &sout_info.out_data_slice);
        defer sout.delete();
        // header, skip and set later
        try sout.check_rem(4);
        sout.push_layer(4, 0);
        try sout.check_rem(4);
        sout.out_i32_le(structs.g_proto_version);
        sout.push_layer(0, 1);
        sout.pop_layer(0);
        // header
        const pdu_code = @intFromEnum(structs.MyFuseMsg.version);
        sout.out_u16_le(pdu_code);
        const pdu_size = sout.layer_subtract(1, 0);
        sout.out_u16_le(pdu_size);
        sout_info.msg_size = pdu_size;
        // add to linked list
        try self.append_sout(sout_info);
    }

    //*************************************************************************
    fn process_reply_statfs(self: *fuse_session_t, sin: *parse.parse_t) !void
    {
        _ = self;
        try log.logln(log.LogLevel.info, @src(), "", .{});
        try sin.check_rem(8);
        const req = sin.in_u64_le();
        var mstat: structs.MyStatVfs = .{};
        try mstat.in(sin);
        var cstat: c.struct_statvfs = .{};
        fromMyStatVfs(&mstat, &cstat);
        const req_ptr: *c.struct_fuse_req = @ptrFromInt(req);
        _ = c.fuse_reply_statfs(req_ptr, &cstat);
    }

    //*************************************************************************
    fn process_reply_attr(self: *fuse_session_t, sin: *parse.parse_t) !void
    {
        _ = self;
        try log.logln(log.LogLevel.info, @src(), "", .{});
        try sin.check_rem(8);
        const req = sin.in_u64_le();
        var mstat: structs.MyStat = .{};
        try mstat.in(sin);
        var cstat: c.struct_stat = .{};
        fromMyStat(&mstat, &cstat);
        try sin.check_rem(8);
        const attr_timeout = sin.in_f64_le();
        try log.logln_devel(log.LogLevel.info, @src(),
                "st_mode {} attr_timeout {}",
                .{cstat.st_mode, attr_timeout});
        const req_ptr: *c.struct_fuse_req = @ptrFromInt(req);
        _ = c.fuse_reply_attr(req_ptr, &cstat, attr_timeout);
    }

    //*************************************************************************
    fn process_reply_create(self: *fuse_session_t, sin: *parse.parse_t) !void
    {
        _ = self;
        try log.logln(log.LogLevel.info, @src(), "", .{});
        try sin.check_rem(8);
        const req = sin.in_u64_le();
        var mep: structs.MyEntryParam = .{};
        try mep.in(sin);
        var cep: c.fuse_entry_param = .{};
        fromMyEntryParam(&mep, &cep);
        const req_ptr: *c.struct_fuse_req = @ptrFromInt(req);
        const got_fi = sin.in_u8();
        if (got_fi != 0)
        {
            var mfi: structs.MyFileInfo = .{};
            try mfi.in(sin);
            const cfi = c.myfuse_file_info_create(mfi.flags, mfi.padding,
                    mfi.fh, mfi.lock_owner, mfi.poll_events, mfi.backing_id,
                    mfi.compat_flags);
            _ = c.fuse_reply_create(req_ptr, &cep, cfi);
            c.myfuse_file_info_delete(cfi);
        }
        else
        {
            _ = c.fuse_reply_create(req_ptr, &cep, null);
        }
    }

    //*************************************************************************
    fn process_reply_write(self: *fuse_session_t, sin: *parse.parse_t) !void
    {
        _ = self;
        try log.logln(log.LogLevel.info, @src(), "", .{});
        try sin.check_rem(16);
        const req = sin.in_u64_le();
        const count = sin.in_u64_le();
        const req_ptr: *c.struct_fuse_req = @ptrFromInt(req);
        _ = c.fuse_reply_write(req_ptr, count);
    }

    //*************************************************************************
    fn process_reply_buf(self: *fuse_session_t, sin: *parse.parse_t) !void
    {
        _ = self;
        try log.logln(log.LogLevel.info, @src(), "", .{});
        try sin.check_rem(10);
        const req = sin.in_u64_le();
        const buf_size = sin.in_u16_le();
        try log.logln_devel(log.LogLevel.info, @src(),
                "buf_size {}", .{buf_size});
        try sin.check_rem(buf_size);
        const buf = sin.in_u8_slice(buf_size);
        const req_ptr: *c.struct_fuse_req = @ptrFromInt(req);
        _ = c.fuse_reply_buf(req_ptr, buf.ptr, buf_size);
    }

    //*************************************************************************
    fn process_reply_buf_dir(self: *fuse_session_t, sin: *parse.parse_t) !void
    {
        _ = self;
        try log.logln(log.LogLevel.info, @src(), "", .{});
        try sin.check_rem(3 * 8 + 2);
        const req = sin.in_u64_le();
        const size = sin.in_u64_le();
        const off = sin.in_i64_le();
        const req_ptr: *c.struct_fuse_req = @ptrFromInt(req);
        const num_dir_items: usize  = sin.in_u16_le();
        try log.logln_devel(log.LogLevel.info, @src(),
                "size {} off {} num_dir_items {}",
                .{size, off, num_dir_items});
        const buf = try g_allocator.alloc(u8, size);
        defer g_allocator.free(buf);
        var total_size: usize = 0;
        var stbuf: c.struct_stat = undefined;
        var index: usize = 0;
        while (index < num_dir_items) : (index += 1)
        {
            try sin.check_rem(8 + 4 + 2);
            const ino = sin.in_u64_le();
            const mode = sin.in_u32_le();
            const name_len = sin.in_u16_le();
            try sin.check_rem(name_len);
            const name = sin.in_u8_slice(name_len);
            stbuf = .{};
            stbuf.st_ino = ino;
            stbuf.st_mode = mode;
            total_size += c.fuse_add_direntry(req_ptr,
                    buf.ptr + total_size, size - total_size,
                    name.ptr, &stbuf, -1);
            try log.logln_devel(log.LogLevel.info, @src(),
                    "ino {} mode {} name_len {} name {s} total_size {}",
                    .{ino, mode, name_len, name, total_size});
        }
        const off_usize: usize = @intCast(off);
        _ = c.fuse_reply_buf(req_ptr,
                buf.ptr + off_usize,
                @min(size, total_size - off_usize));
    }

    //*************************************************************************
    fn process_reply_iov(self: *fuse_session_t, sin: *parse.parse_t) !void
    {
        _ = self;
        try log.logln(log.LogLevel.info, @src(), "", .{});
        try sin.check_rem(12);
        const req = sin.in_u64_le();
        const count = sin.in_u32_le();
        const iovecs = try g_allocator.alloc(c.struct_iovec, count);
        defer g_allocator.free(iovecs);
        for (0..count) |index|
        {
            try sin.check_rem(8);
            const iov_size = sin.in_u64_le();
            try sin.check_rem(iov_size);
            const iov_base_slice = sin.in_u8_slice(iov_size);
            iovecs[index] = .{};
            iovecs[index].iov_len = iov_size;
            iovecs[index].iov_base = iov_base_slice.ptr;
        }
        const req_ptr: *c.struct_fuse_req = @ptrFromInt(req);
        _ = c.fuse_reply_iov(req_ptr, iovecs.ptr, @intCast(count));
    }

    //*************************************************************************
    fn process_reply_data(self: *fuse_session_t, sin: *parse.parse_t) !void
    {
        _ = self;
        try log.logln(log.LogLevel.info, @src(), "", .{});
        try sin.check_rem(16);
        const req = sin.in_u64_le();
        const count = sin.in_u64_le();
        const bufv: ?*c.fuse_bufvec = c.myfuse_bufvec_create(count);
        if (bufv) |abufv|
        {
            defer c.myfuse_bufvec_delete(abufv);
            abufv.count = count;
            abufv.idx = sin.in_u64_le();
            abufv.off = sin.in_u64_le();
            for (0..count) | index|
            {
                var buf: c.fuse_buf = .{};
                buf.size = sin.in_u64_le();
                buf.flags = sin.in_u32_le();
                const mem_slice = sin.in_u8_slice(buf.size);
                buf.mem = mem_slice.ptr;
                buf.fd = sin.in_i32_le();
                buf.pos = sin.in_i64_le();
                //buf.mem_size = sin.in_u64_le();
                _ = sin.in_u64_le();
                c.myfuse_bufvec_set(abufv, index, &buf);
            }
            const flags = sin.in_u32_le();
            const req_ptr: *c.struct_fuse_req = @ptrFromInt(req);
            _ = c.fuse_reply_data(req_ptr, abufv, flags);
        }
    }

    //*************************************************************************
    fn process_reply_open(self: *fuse_session_t, sin: *parse.parse_t) !void
    {
        _ = self;
        try log.logln(log.LogLevel.info, @src(), "", .{});
        try sin.check_rem(8);
        const req = sin.in_u64_le();
        var mfi: structs.MyFileInfo = .{};
        try mfi.in(sin);
        const cfi = c.myfuse_file_info_create(mfi.flags, mfi.padding,
                mfi.fh, mfi.lock_owner, mfi.poll_events, mfi.backing_id,
                mfi.compat_flags);
        const req_ptr: *c.struct_fuse_req = @ptrFromInt(req);
        _ = c.fuse_reply_open(req_ptr, cfi);
        c.myfuse_file_info_delete(cfi);
    }

    //*************************************************************************
    fn process_reply_entry(self: *fuse_session_t, sin: *parse.parse_t) !void
    {
        _ = self;
        try log.logln(log.LogLevel.info, @src(), "", .{});
        try sin.check_rem(8);
        const req = sin.in_u64_le();
        var meq: structs.MyEntryParam = .{};
        try meq.in(sin);
        var ceq: c.fuse_entry_param = .{};
        fromMyEntryParam(&meq, &ceq);
        const req_ptr: *c.struct_fuse_req = @ptrFromInt(req);
        _ = c.fuse_reply_entry(req_ptr, &ceq);
    }

    //*************************************************************************
    fn process_reply_err(self: *fuse_session_t, sin: *parse.parse_t) !void
    {
        _ = self;
        try log.logln(log.LogLevel.info, @src(), "", .{});
        try sin.check_rem(8 + 4);
        const req = sin.in_u64_le();
        const ierr = sin.in_i32_le();
        const req_ptr: *c.struct_fuse_req = @ptrFromInt(req);
        _ = c.fuse_reply_err(req_ptr, ierr);
    }

    //*************************************************************************
    fn process_other(self: *fuse_session_t,
            pdu_code: structs.MyFuseReplyMsg) !void
    {
        _ = self;
        try log.logln(log.LogLevel.info, @src(), "pdu_code {}", .{pdu_code});
    }

    //*************************************************************************
    pub fn process_msg(self: *fuse_session_t, in_data_slice: []u8) !void
    {
        try log.logln_devel(log.LogLevel.info, @src(), "", .{});
        const sin = try parse.parse_t.create_from_slice(&g_allocator,
                in_data_slice);
        defer sin.delete();
        try sin.check_rem(4);
        const pdu_code: structs.MyFuseReplyMsg = @enumFromInt(sin.in_u16_le());
        sin.in_u8_skip(2); // pdu_size
        return switch (pdu_code)
        {
            .statfs => self.process_reply_statfs(sin),      // yes
            .attr => self.process_reply_attr(sin),          // yes
            .create => self.process_reply_create(sin),      // yes
            .write => self.process_reply_write(sin),        // yes
            .buf => self.process_reply_buf(sin),            // yes
            .buf_dir => self.process_reply_buf_dir(sin),    // yes
            .iov => self.process_reply_iov(sin),
            .data => self.process_reply_data(sin),
            .open => self.process_reply_open(sin),          // yes
            .entry => self.process_reply_entry(sin),        // yes
            .err => self.process_reply_err(sin),            // yes
            else => self.process_other(pdu_code),
        };
    }

    //*************************************************************************
    // * Valid replies:
    // *   fuse_reply_entry
    // *   fuse_reply_err
    fn lookup(self: *fuse_session_t, req: c.fuse_req_t,
            parent: c.fuse_ino_t, name: ?[*:0]const u8) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        if (req) |areq|
        {
            if (name) |aname|
            {
                const str = std.mem.sliceTo(aname, 0);
                try log.logln_devel(log.LogLevel.info, @src(),
                        "self [0x{X}] req [0x{X}] parent [0x{X}] name [{s}]",
                        .{@intFromPtr(self), @intFromPtr(areq), parent, str});
                // create sout_info
                const sout_info = try g_allocator.create(sout_info_t);
                errdefer g_allocator.destroy(sout_info);
                try sout_info.init();
                errdefer sout_info.deinit();
                // create a temp parse
                const sout = try parse.parse_t.create_from_slice(
                        &g_allocator, &sout_info.out_data_slice);
                defer sout.delete();
                // header, skip and set later
                try sout.check_rem(4);
                sout.push_layer(4, 0);
                // req, parent
                try sout.check_rem(8 + 8);
                sout.out_u64_le(@intFromPtr(areq));
                sout.out_u64_le(parent);
                // string
                try sout.check_rem(2 + str.len + 1);
                sout.out_u16_le(@intCast(str.len + 1));
                sout.out_u8_slice(str);
                sout.out_u8(0);
                sout.push_layer(0, 1);
                sout.pop_layer(0);
                // header
                const pdu_code = @intFromEnum(structs.MyFuseMsg.lookup);
                sout.out_u16_le(pdu_code);
                const pdu_size = sout.layer_subtract(1, 0);
                sout.out_u16_le(pdu_size);
                sout_info.msg_size = pdu_size;
                // add to linked list
                try self.append_sout(sout_info);
                return;
            }
        }
        _ = c.fuse_reply_err(req, c.ENOENT);
    }

    //*************************************************************************
    // * Valid replies:
	// *   fuse_reply_buf
	// *   fuse_reply_data
	// *   fuse_reply_err
    fn readdir(self: *fuse_session_t, req: c.fuse_req_t, ino: c.fuse_ino_t,
            size: usize, off: c.off_t, fi: ?*c.fuse_file_info) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        try log.logln_devel(log.LogLevel.info, @src(),
                "size {} off {}", .{size, off});
        if (req) |areq|
        {
            if (off < 0)
            {
                _ = c.fuse_reply_buf(areq, null, 0);
                return;
            }
            // create sout_info
            const sout_info = try g_allocator.create(sout_info_t);
            errdefer g_allocator.destroy(sout_info);
            try sout_info.init();
            errdefer sout_info.deinit();
            // create a temp parse
            const sout = try parse.parse_t.create_from_slice(
                    &g_allocator, &sout_info.out_data_slice);
            defer sout.delete();
            // header, skip and set later
            try sout.check_rem(4);
            sout.push_layer(4, 0);
            // req, ino, size, off
            try sout.check_rem(4 * 8 + 1);
            sout.out_u64_le(@intFromPtr(areq));
            sout.out_u64_le(ino);
            sout.out_u64_le(size);
            sout.out_i64_le(off);
            if (fi) |afi|
            {
                try log.logln_devel(log.LogLevel.info, @src(), "fi yes", .{});
                sout.out_u8(1);
                var mfi: structs.MyFileInfo = .{};
                toMyFileInfo(afi, &mfi);
                try mfi.out(sout);
            }
            else
            {
                try log.logln_devel(log.LogLevel.info, @src(), "fi no", .{});
                sout.out_u8(0);
            }
            sout.push_layer(0, 1);
            sout.pop_layer(0);
            // header
            const pdu_code = @intFromEnum(structs.MyFuseMsg.readdir);
            sout.out_u16_le(pdu_code);
            const pdu_size = sout.layer_subtract(1, 0);
            sout.out_u16_le(pdu_size);
            sout_info.msg_size = pdu_size;
            // add to linked list
            try self.append_sout(sout_info);
            return;
         }
        _ = c.fuse_reply_err(req, c.ENOTDIR);
    }

    //*************************************************************************
    // * Valid replies:
    // *   fuse_reply_entry
    // *   fuse_reply_err
    fn mkdir(self: *fuse_session_t, req: c.fuse_req_t, parent: c.fuse_ino_t,
            name: ?[*:0]const u8, mode: c.mode_t) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        if (req) |areq|
        {
            if (name) |aname|
            {
                const str = std.mem.sliceTo(aname, 0);
                // create sout_info
                const sout_info = try g_allocator.create(sout_info_t);
                errdefer g_allocator.destroy(sout_info);
                try sout_info.init();
                errdefer sout_info.deinit();
                // create a temp parse
                const sout = try parse.parse_t.create_from_slice(
                        &g_allocator, &sout_info.out_data_slice);
                defer sout.delete();
                // header, skip and set later
                try sout.check_rem(4);
                sout.push_layer(4, 0);
                // req
                try sout.check_rem(8 + 8 + 2 + str.len + 1 + 4);
                sout.out_u64_le(@intFromPtr(areq));
                sout.out_u64_le(parent);
                sout.out_u16_le(@intCast(str.len + 1));
                sout.out_u8_slice(str);
                sout.out_u8(0);
                sout.out_u32_le(mode);
                sout.push_layer(0, 1);
                sout.pop_layer(0);
                // header
                const pdu_code = @intFromEnum(structs.MyFuseMsg.mkdir);
                sout.out_u16_le(pdu_code);
                const pdu_size = sout.layer_subtract(1, 0);
                sout.out_u16_le(pdu_size);
                sout_info.msg_size = pdu_size;
                // add to linked list
                try self.append_sout(sout_info);
                return;
            }
        }
        _ = c.fuse_reply_err(req, c.ENOENT);
    }

    //*************************************************************************
    // * Valid replies:
    // *   fuse_reply_err
    fn rmdir(self: *fuse_session_t, req: c.fuse_req_t, parent: c.fuse_ino_t,
            name: ?[*:0]const u8) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        if (req) |areq|
        {
            if (name) |aname|
            {
                const str = std.mem.sliceTo(aname, 0);
                // create sout_info
                const sout_info = try g_allocator.create(sout_info_t);
                errdefer g_allocator.destroy(sout_info);
                try sout_info.init();
                errdefer sout_info.deinit();
                // create a temp parse
                const sout = try parse.parse_t.create_from_slice(
                        &g_allocator, &sout_info.out_data_slice);
                defer sout.delete();
                // header, skip and set later
                try sout.check_rem(4);
                sout.push_layer(4, 0);
                // req
                try sout.check_rem(8 + 8 + 2 + str.len + 1);
                sout.out_u64_le(@intFromPtr(areq));
                sout.out_u64_le(parent);
                sout.out_u16_le(@intCast(str.len + 1));
                sout.out_u8_slice(str);
                sout.out_u8(0);
                sout.push_layer(0, 1);
                sout.pop_layer(0);
                // header
                const pdu_code = @intFromEnum(structs.MyFuseMsg.rmdir);
                sout.out_u16_le(pdu_code);
                const pdu_size = sout.layer_subtract(1, 0);
                sout.out_u16_le(pdu_size);
                sout_info.msg_size = pdu_size;
                // add to linked list
                try self.append_sout(sout_info);
                return;
            }
        }
        _ = c.fuse_reply_err(req, c.ENOENT);
    }

    //*************************************************************************
    // * Valid replies:
    // *   fuse_reply_err
    fn unlink(self: *fuse_session_t, req: c.fuse_req_t, parent: c.fuse_ino_t,
            name: ?[*:0]const u8) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        if (req) |areq|
        {
            if (name) |aname|
            {
                const str = std.mem.sliceTo(aname, 0);
                // create sout_info
                const sout_info = try g_allocator.create(sout_info_t);
                errdefer g_allocator.destroy(sout_info);
                try sout_info.init();
                errdefer sout_info.deinit();
                // create a temp parse
                const sout = try parse.parse_t.create_from_slice(
                        &g_allocator, &sout_info.out_data_slice);
                defer sout.delete();
                // header, skip and set later
                try sout.check_rem(4);
                sout.push_layer(4, 0);
                // req
                try sout.check_rem(8 + 8 + 2 + str.len + 1);
                sout.out_u64_le(@intFromPtr(areq));
                sout.out_u64_le(parent);
                sout.out_u16_le(@intCast(str.len + 1));
                sout.out_u8_slice(str);
                sout.out_u8(0);
                sout.push_layer(0, 1);
                sout.pop_layer(0);
                // header
                const pdu_code = @intFromEnum(structs.MyFuseMsg.unlink);
                sout.out_u16_le(pdu_code);
                const pdu_size = sout.layer_subtract(1, 0);
                sout.out_u16_le(pdu_size);
                sout_info.msg_size = pdu_size;
                // add to linked list
                try self.append_sout(sout_info);
                return;
            }
        }
        _ = c.fuse_reply_err(req, c.ENOENT);
    }

    //*************************************************************************
    // * Valid replies:
    // *   fuse_reply_err
    fn rename(self: *fuse_session_t, req: c.fuse_req_t,
            old_parent: c.fuse_ino_t, old_name: ?[*:0]const u8,
            new_parent: c.fuse_ino_t, new_name: ?[*:0]const u8,
            flags: c_uint) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        if (req) |areq|
        {
            if (old_name) |aold_name|
            {
                if (new_name) |anew_name|
                {
                    const old_name_str = std.mem.sliceTo(aold_name, 0);
                    const new_name_str = std.mem.sliceTo(anew_name, 0);
                    try log.logln_devel(log.LogLevel.info, @src(),
                            "old_name_str.len [{}] new_name_str.len [{}]",
                            .{old_name_str.len, new_name_str.len});
                    // create sout_info
                    const sout_info = try g_allocator.create(sout_info_t);
                    errdefer g_allocator.destroy(sout_info);
                    try sout_info.init();
                    errdefer sout_info.deinit();
                    // create a temp parse
                    const sout = try parse.parse_t.create_from_slice(
                            &g_allocator, &sout_info.out_data_slice);
                    defer sout.delete();
                    // header, skip and set later
                    try sout.check_rem(4);
                    sout.push_layer(4, 0);
                    // req, ino, size, off
                    try sout.check_rem(8 +
                            8 + 2 + old_name_str.len + 1 +
                            8 + 2 + new_name_str.len + 1 + 4);
                    sout.out_u64_le(@intFromPtr(areq));
                    sout.out_u64_le(old_parent);
                    sout.out_u16_le(@intCast(old_name_str.len + 1));
                    sout.out_u8_slice(old_name_str);
                    sout.out_u8(0);
                    sout.out_u64_le(new_parent);
                    sout.out_u16_le(@intCast(new_name_str.len + 1));
                    sout.out_u8_slice(new_name_str);
                    sout.out_u8(0);
                    sout.out_u32_le(flags);
                    sout.push_layer(0, 1);
                    sout.pop_layer(0);
                    // header
                    const pdu_code = @intFromEnum(structs.MyFuseMsg.rename);
                    sout.out_u16_le(pdu_code);
                    const pdu_size = sout.layer_subtract(1, 0);
                    sout.out_u16_le(pdu_size);
                    sout_info.msg_size = pdu_size;
                    // add to linked list
                    try self.append_sout(sout_info);
                    return;
                }
            }
        }
        _ = c.fuse_reply_err(req, c.ENOENT);
    }

    //*************************************************************************
    // * Valid replies:
    // *   fuse_reply_open
    // *   fuse_reply_err
    fn open(self: *fuse_session_t, req: c.fuse_req_t, ino: c.fuse_ino_t,
            fi: ?*c.fuse_file_info) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        if (req) |areq|
        {
            // create sout_info
            const sout_info = try g_allocator.create(sout_info_t);
            errdefer g_allocator.destroy(sout_info);
            try sout_info.init();
            errdefer sout_info.deinit();
            // create a temp parse
            const sout = try parse.parse_t.create_from_slice(
                    &g_allocator, &sout_info.out_data_slice);
            defer sout.delete();
            // header, skip and set later
            try sout.check_rem(4);
            sout.push_layer(4, 0);
            // req, ino, size, off
            try sout.check_rem(8 + 8 + 1);
            sout.out_u64_le(@intFromPtr(areq));
            sout.out_u64_le(ino);
            if (fi) |afi|
            {
                try log.logln_devel(log.LogLevel.info, @src(), "fi yes", .{});
                sout.out_u8(1);
                var mfi: structs.MyFileInfo = .{};
                toMyFileInfo(afi, &mfi);
                try mfi.out(sout);
            }
            else
            {
                try log.logln_devel(log.LogLevel.info, @src(), "fi no", .{});
                sout.out_u8(0);
            }
            sout.push_layer(0, 1);
            sout.pop_layer(0);
            // header
            const pdu_code = @intFromEnum(structs.MyFuseMsg.open);
            sout.out_u16_le(pdu_code);
            const pdu_size = sout.layer_subtract(1, 0);
            sout.out_u16_le(pdu_size);
            sout_info.msg_size = pdu_size;
            // add to linked list
            try self.append_sout(sout_info);
            return;
         }
        _ = c.fuse_reply_err(req, c.ENOENT);
    }

    //*************************************************************************
    // * Valid replies:
    // *   fuse_reply_err
    fn release(self: *fuse_session_t, req: c.fuse_req_t, ino: c.fuse_ino_t,
            fi: ?*c.fuse_file_info) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        if (req) |areq|
        {
            // create sout_info
            const sout_info = try g_allocator.create(sout_info_t);
            errdefer g_allocator.destroy(sout_info);
            try sout_info.init();
            errdefer sout_info.deinit();
            // create a temp parse
            const sout = try parse.parse_t.create_from_slice(
                    &g_allocator, &sout_info.out_data_slice);
            defer sout.delete();
            // header, skip and set later
            try sout.check_rem(4);
            sout.push_layer(4, 0);
            // req, ino, size, off
            try sout.check_rem(8 + 8 + 1);
            sout.out_u64_le(@intFromPtr(areq));
            sout.out_u64_le(ino);
            if (fi) |afi|
            {
                try log.logln_devel(log.LogLevel.info, @src(), "fi yes", .{});
                sout.out_u8(1);
                var mfi: structs.MyFileInfo = .{};
                toMyFileInfo(afi, &mfi);
                try mfi.out(sout);
            }
            else
            {
                try log.logln_devel(log.LogLevel.info, @src(), "fi no", .{});
                sout.out_u8(0);
            }
            sout.push_layer(0, 1);
            sout.pop_layer(0);
            // header
            const pdu_code = @intFromEnum(structs.MyFuseMsg.release);
            sout.out_u16_le(pdu_code);
            const pdu_size = sout.layer_subtract(1, 0);
            sout.out_u16_le(pdu_size);
            sout_info.msg_size = pdu_size;
            // add to linked list
            try self.append_sout(sout_info);
            return;
         }
    }

    //*************************************************************************
    // * Valid replies:
    // *   fuse_reply_buf
    // *   fuse_reply_iov
    // *   fuse_reply_data
    // *   fuse_reply_err
    fn read(self: *fuse_session_t, req: c.fuse_req_t, ino: c.fuse_ino_t,
            size: usize, off: c.off_t, fi: ?*c.fuse_file_info) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        try log.logln_devel(log.LogLevel.info, @src(),
                "size {} off {}", .{size, off});
        if (req) |areq|
        {
            if (off < 0)
            {
                _ = c.fuse_reply_buf(areq, null, 0);
                return;
            }
            // create sout_info
            const sout_info = try g_allocator.create(sout_info_t);
            errdefer g_allocator.destroy(sout_info);
            try sout_info.init();
            errdefer sout_info.deinit();
            // create a temp parse
            const sout = try parse.parse_t.create_from_slice(
                    &g_allocator, &sout_info.out_data_slice);
            defer sout.delete();
            // header, skip and set later
            try sout.check_rem(4);
            sout.push_layer(4, 0);
            // req, ino, size, off
            try sout.check_rem(4 * 8 + 1);
            sout.out_u64_le(@intFromPtr(areq));
            sout.out_u64_le(ino);
            sout.out_u64_le(size);
            sout.out_i64_le(off);
            if (fi) |afi|
            {
                try log.logln_devel(log.LogLevel.info, @src(), "fi yes", .{});
                sout.out_u8(1);
                var mfi: structs.MyFileInfo = .{};
                toMyFileInfo(afi, &mfi);
                try mfi.out(sout);
            }
            else
            {
                try log.logln_devel(log.LogLevel.info, @src(), "fi no", .{});
                sout.out_u8(0);
            }
            sout.push_layer(0, 1);
            sout.pop_layer(0);
            // header
            const code = @intFromEnum(structs.MyFuseMsg.read);
            sout.out_u16_le(code);
            const pdu_size = sout.layer_subtract(1, 0);
            sout.out_u16_le(pdu_size);
            sout_info.msg_size = pdu_size;
            // add to linked list
            try self.append_sout(sout_info);
            return;
         }
        _ = c.fuse_reply_err(req, c.ENOENT);
    }

    //*************************************************************************
    // * Valid replies:
    // *   fuse_reply_write
    // *   fuse_reply_err
    fn write(self: *fuse_session_t, req: c.fuse_req_t, ino: c.fuse_ino_t,
            buf: ?[*]const u8, size: usize, off: c.off_t,
            fi: ?*c.fuse_file_info) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        try log.logln(log.LogLevel.info, @src(),
                "size {} off {}", .{size, off});
        if (req) |areq|
        {
            // create sout_info
            const sout_info = try g_allocator.create(sout_info_t);
            errdefer g_allocator.destroy(sout_info);
            try sout_info.init();
            errdefer sout_info.deinit();
            // create a temp parse
            const sout = try parse.parse_t.create_from_slice(
                    &g_allocator, &sout_info.out_data_slice);
            defer sout.delete();
            // header, skip and set later
            try sout.check_rem(4);
            sout.push_layer(4, 0);
            // req, ino, size, off
            try sout.check_rem(3 * 8);
            sout.out_u64_le(@intFromPtr(areq));
            sout.out_u64_le(ino);
            if (buf) |abuf|
            {
                sout.out_u64_le(size);
                try sout.check_rem(size);
                sout.out_u8_slice(abuf[0..size]);
            }
            else
            {
                sout.out_u64_le(0);
            }
            try sout.check_rem(8 + 1);
            sout.out_i64_le(off);
            if (fi) |afi|
            {
                try log.logln_devel(log.LogLevel.info, @src(), "fi yes", .{});
                sout.out_u8(1);
                var mfi: structs.MyFileInfo = .{};
                toMyFileInfo(afi, &mfi);
                try mfi.out(sout);
            }
            else
            {
                try log.logln_devel(log.LogLevel.info, @src(), "fi no", .{});
                sout.out_u8(0);
            }
            sout.push_layer(0, 1);
            sout.pop_layer(0);
            // header
            const pdu_code = @intFromEnum(structs.MyFuseMsg.write);
            sout.out_u16_le(pdu_code);
            const pdu_size = sout.layer_subtract(1, 0);
            sout.out_u16_le(pdu_size);
            sout_info.msg_size = pdu_size;
            // add to linked list
            try self.append_sout(sout_info);
            return;
         }
        _ = c.fuse_reply_err(req, c.ENOENT);
    }

    //*************************************************************************
    // * Valid replies:
    // *   fuse_reply_create
    // *   fuse_reply_err
    fn create(self: *fuse_session_t, req: c.fuse_req_t, parent: c.fuse_ino_t,
            name: ?[*:0]const u8, mode: c.mode_t, fi: ?*c.fuse_file_info) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        if (req) |areq|
        {
            if (name) |aname|
            {
                const name_str = std.mem.sliceTo(aname, 0);
                // create sout_info
                const sout_info = try g_allocator.create(sout_info_t);
                errdefer g_allocator.destroy(sout_info);
                try sout_info.init();
                errdefer sout_info.deinit();
                // create a temp parse
                const sout = try parse.parse_t.create_from_slice(
                        &g_allocator, &sout_info.out_data_slice);
                defer sout.delete();
                // header, skip and set later
                try sout.check_rem(4);
                sout.push_layer(4, 0);
                // req
                try sout.check_rem(8 + 8 + 2 + name_str.len + 1 + 4 + 1);
                sout.out_u64_le(@intFromPtr(areq));
                sout.out_u64_le(parent);
                sout.out_u16_le(@intCast(name_str.len + 1));
                sout.out_u8_slice(name_str);
                sout.out_u8(0);
                sout.out_u32_le(mode);
                if (fi) |afi|
                {
                    try log.logln_devel(log.LogLevel.info, @src(), "fi yes", .{});
                    sout.out_u8(1);
                    var mfi: structs.MyFileInfo = .{};
                    toMyFileInfo(afi, &mfi);
                    try mfi.out(sout);
                }
                else
                {
                    try log.logln_devel(log.LogLevel.info, @src(), "fi no", .{});
                    sout.out_u8(0);
                }
                sout.push_layer(0, 1);
                sout.pop_layer(0);
                // header
                const pdu_code = @intFromEnum(structs.MyFuseMsg.create);
                sout.out_u16_le(pdu_code);
                const pdu_size = sout.layer_subtract(1, 0);
                sout.out_u16_le(pdu_size);
                sout_info.msg_size = pdu_size;
                // add to linked list
                try self.append_sout(sout_info);
                return;
            }
         }
        _ = c.fuse_reply_err(req, c.ENOENT);
    }

    //*************************************************************************
    // * Valid replies:
    // *   fuse_reply_err
    fn fsync(self: *fuse_session_t, req: c.fuse_req_t, ino: c.fuse_ino_t,
            datasync: c_int, fi: ?*c.fuse_file_info) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        if (req) |areq|
        {
            // create sout_info
            const sout_info = try g_allocator.create(sout_info_t);
            errdefer g_allocator.destroy(sout_info);
            try sout_info.init();
            errdefer sout_info.deinit();
            // create a temp parse
            const sout = try parse.parse_t.create_from_slice(
                    &g_allocator, &sout_info.out_data_slice);
            defer sout.delete();
            // header, skip and set later
            try sout.check_rem(4);
            sout.push_layer(4, 0);
            // req
            try sout.check_rem(8 + 8 + 4 + 1);
            sout.out_u64_le(@intFromPtr(areq));
            sout.out_u64_le(ino);
            sout.out_i32_le(datasync);
            if (fi) |afi|
            {
                try log.logln_devel(log.LogLevel.info, @src(), "fi yes", .{});
                sout.out_u8(1);
                var mfi: structs.MyFileInfo = .{};
                toMyFileInfo(afi, &mfi);
                try mfi.out(sout);
            }
            else
            {
                try log.logln_devel(log.LogLevel.info, @src(), "fi no", .{});
                sout.out_u8(0);
            }
            sout.push_layer(0, 1);
            sout.pop_layer(0);
            // header
            const pdu_code = @intFromEnum(structs.MyFuseMsg.fsync);
            sout.out_u16_le(pdu_code);
            const pdu_size = sout.layer_subtract(1, 0);
            sout.out_u16_le(pdu_size);
            sout_info.msg_size = pdu_size;
            // add to linked list
            try self.append_sout(sout_info);
            return;
         }
        _ = c.fuse_reply_err(req, c.ENOENT);
    }

    //*************************************************************************
    // * Valid replies:
    // *   fuse_reply_attr
    // *   fuse_reply_err
    fn getattr(self: *fuse_session_t, req: c.fuse_req_t, ino: c.fuse_ino_t,
            fi: ?*c.fuse_file_info) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        if (req) |areq|
        {
            try log.logln_devel(log.LogLevel.info, @src(),
                    "self [0x{X}] req [0x{X}] ino [0x{X}]",
                    .{@intFromPtr(self), @intFromPtr(areq), ino});
            // create sout_info
            const sout_info = try g_allocator.create(sout_info_t);
            errdefer g_allocator.destroy(sout_info);
            try sout_info.init();
            errdefer sout_info.deinit();
            // create a temp parse
            const sout = try parse.parse_t.create_from_slice(
                    &g_allocator, &sout_info.out_data_slice);
            defer sout.delete();
            // header, skip and set later
            try sout.check_rem(4);
            sout.push_layer(4, 0);
            // req, ino
            try sout.check_rem(8 + 8 + 1);
            sout.out_u64_le(@intFromPtr(areq));
            sout.out_u64_le(ino);
            if (fi) |afi|
            {
                try log.logln_devel(log.LogLevel.info, @src(), "fi yes", .{});
                sout.out_u8(1);
                var mfi: structs.MyFileInfo = .{};
                toMyFileInfo(afi, &mfi);
                try mfi.out(sout);
            }
            else
            {
                try log.logln_devel(log.LogLevel.info, @src(), "fi no", .{});
                sout.out_u8(0);
            }
            sout.push_layer(0, 1);
            sout.pop_layer(0);
            // header
            const pdu_code = @intFromEnum(structs.MyFuseMsg.getattr);
            sout.out_u16_le(pdu_code);
            const pdu_size = sout.layer_subtract(1, 0);
            sout.out_u16_le(pdu_size);
            sout_info.msg_size = pdu_size;
            // add to linked list
            try self.append_sout(sout_info);
            return;
        }
        _ = c.fuse_reply_err(req, c.ENOENT);
    }

    //*************************************************************************
    // * Valid replies:
    // *   fuse_reply_attr
    // *   fuse_reply_err
    fn setattr(self: *fuse_session_t, req: c.fuse_req_t, ino: c.fuse_ino_t,
            attr: ?*c.struct_stat, to_set: c_int, fi: ?*c.fuse_file_info) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        if (req) |areq|
        {
            try log.logln_devel(log.LogLevel.info, @src(),
                    "self [0x{X}] req [0x{X}] ino [0x{X}]",
                    .{@intFromPtr(self), @intFromPtr(areq), ino});
            // create sout_info
            const sout_info = try g_allocator.create(sout_info_t);
            errdefer g_allocator.destroy(sout_info);
            try sout_info.init();
            errdefer sout_info.deinit();
            // create a temp parse
            const sout = try parse.parse_t.create_from_slice(
                    &g_allocator, &sout_info.out_data_slice);
            defer sout.delete();
            // header, skip and set later
            try sout.check_rem(4);
            sout.push_layer(4, 0);
            // req, ino
            try sout.check_rem(8 + 8 + 1);
            sout.out_u64_le(@intFromPtr(areq));
            sout.out_u64_le(ino);
            if (attr) |aattr|
            {
                try log.logln_devel(log.LogLevel.info, @src(), "attr yes", .{});
                sout.out_u8(1);
                var mattr: structs.MyStat = .{};
                toMyStat(aattr, &mattr);
                try mattr.out(sout);
            }
            else
            {
                try log.logln_devel(log.LogLevel.info, @src(), "attr no", .{});
                sout.out_u8(0);
            }
            try sout.check_rem(4 + 1);
            sout.out_i32_le(to_set);
            if (fi) |afi|
            {
                try log.logln_devel(log.LogLevel.info, @src(), "fi yes", .{});
                sout.out_u8(1);
                var mfi: structs.MyFileInfo = .{};
                toMyFileInfo(afi, &mfi);
                try mfi.out(sout);
            }
            else
            {
                try log.logln_devel(log.LogLevel.info, @src(), "fi no", .{});
                sout.out_u8(0);
            }
            sout.push_layer(0, 1);
            sout.pop_layer(0);
            // header
            const pdu_code = @intFromEnum(structs.MyFuseMsg.setattr);
            sout.out_u16_le(pdu_code);
            const pdu_size = sout.layer_subtract(1, 0);
            sout.out_u16_le(pdu_size);
            sout_info.msg_size = pdu_size;
            // add to linked list
            try self.append_sout(sout_info);
            return;
        }
        _ = c.fuse_reply_err(req, c.ENOENT);
    }

    //*************************************************************************
    // * Valid replies:
    // *   fuse_reply_open
    // *   fuse_reply_err
    fn opendir(self: *fuse_session_t, req: c.fuse_req_t, ino: c.fuse_ino_t,
            fi: ?*c.fuse_file_info) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        if (req) |areq|
        {
            try log.logln_devel(log.LogLevel.info, @src(),
                    "self [0x{X}] req [0x{X}] ino [0x{X}]",
                    .{@intFromPtr(self), @intFromPtr(areq), ino});
            // create sout_info
            const sout_info = try g_allocator.create(sout_info_t);
            errdefer g_allocator.destroy(sout_info);
            try sout_info.init();
            errdefer sout_info.deinit();
            // create a temp parse
            const sout = try parse.parse_t.create_from_slice(
                    &g_allocator, &sout_info.out_data_slice);
            defer sout.delete();
            // header, skip and set later
            try sout.check_rem(4);
            sout.push_layer(4, 0);
            // req, ino
            try sout.check_rem(8 + 8 + 1);
            sout.out_u64_le(@intFromPtr(areq));
            sout.out_u64_le(ino);
            if (fi) |afi|
            {
                sout.out_u8(1);
                var mfi: structs.MyFileInfo = .{};
                toMyFileInfo(afi, &mfi);
                try mfi.out(sout);
            }
            else
            {
                sout.out_u8(0);
            }
            sout.push_layer(0, 1);
            sout.pop_layer(0);
            // header
            const pdu_code = @intFromEnum(structs.MyFuseMsg.opendir);
            sout.out_u16_le(pdu_code);
            const pdu_size = sout.layer_subtract(1, 0);
            sout.out_u16_le(pdu_size);
            sout_info.msg_size = pdu_size;
            // add to linked list
            try self.append_sout(sout_info);
            return;
        }
        _ = c.fuse_reply_err(req, c.ENOENT);
    }

    //*************************************************************************
    // * Valid replies:
    // *   fuse_reply_err
    fn releasedir(self: *fuse_session_t, req: c.fuse_req_t, ino: c.fuse_ino_t,
            fi: ?*c.fuse_file_info) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        if (req) |areq|
        {
            try log.logln_devel(log.LogLevel.info, @src(),
                    "self [0x{X}] req [0x{X}] ino [0x{X}]",
                    .{@intFromPtr(self), @intFromPtr(areq), ino});
            // create sout_info
            const sout_info = try g_allocator.create(sout_info_t);
            errdefer g_allocator.destroy(sout_info);
            try sout_info.init();
            errdefer sout_info.deinit();
            // create a temp parse
            const sout = try parse.parse_t.create_from_slice(
                    &g_allocator, &sout_info.out_data_slice);
            defer sout.delete();
            // header, skip and set later
            try sout.check_rem(4);
            sout.push_layer(4, 0);
            // req, ino
            try sout.check_rem(8 + 8 + 1);
            sout.out_u64_le(@intFromPtr(areq));
            sout.out_u64_le(ino);
            if (fi) |afi|
            {
                sout.out_u8(1);
                var mfi: structs.MyFileInfo = .{};
                toMyFileInfo(afi, &mfi);
                try mfi.out(sout);
            }
            else
            {
                sout.out_u8(0);
            }
            sout.push_layer(0, 1);
            sout.pop_layer(0);
            // header
            const pdu_code = @intFromEnum(structs.MyFuseMsg.releasedir);
            sout.out_u16_le(pdu_code);
            const pdu_size = sout.layer_subtract(1, 0);
            sout.out_u16_le(pdu_size);
            sout_info.msg_size = pdu_size;
            // add to linked list
            try self.append_sout(sout_info);
            return;
        }
        _ = c.fuse_reply_err(req, c.ENOENT);
    }

    //*************************************************************************
    // * Valid replies:
    // *   fuse_reply_statfs
    // *   fuse_reply_err
    fn statfs(self: *fuse_session_t, req: c.fuse_req_t,
            ino: c.fuse_ino_t) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        if (req) |areq|
        {
            try log.logln_devel(log.LogLevel.info, @src(),
                    "self [0x{X}] req [0x{X}] ino [0x{X}]",
                    .{@intFromPtr(self), @intFromPtr(areq), ino});
            // create sout_info
            const sout_info = try g_allocator.create(sout_info_t);
            errdefer g_allocator.destroy(sout_info);
            try sout_info.init();
            errdefer sout_info.deinit();
            // create a temp parse
            const sout = try parse.parse_t.create_from_slice(
                    &g_allocator, &sout_info.out_data_slice);
            defer sout.delete();
            // header, skip and set later
            try sout.check_rem(4);
            sout.push_layer(4, 0);
            // req, ino
            try sout.check_rem(8 + 8);
            sout.out_u64_le(@intFromPtr(areq));
            sout.out_u64_le(ino);
            sout.push_layer(0, 1);
            sout.pop_layer(0);
            // header
            const pdu_code = @intFromEnum(structs.MyFuseMsg.statfs);
            sout.out_u16_le(pdu_code);
            const pdu_size = sout.layer_subtract(1, 0);
            sout.out_u16_le(pdu_size);
            sout_info.msg_size = pdu_size;
            // add to linked list
            try self.append_sout(sout_info);
            return;
        }
        _ = c.fuse_reply_err(req, c.ENOENT);
    }

};

//*****************************************************************************
fn toMyFileInfo(src: *c.fuse_file_info, dst: *structs.MyFileInfo) void
{
    c.myfuse_file_info_get(src, &dst.flags, &dst.padding, &dst.fh,
            &dst.lock_owner, &dst.poll_events, &dst.backing_id,
            &dst.compat_flags);
}

//*****************************************************************************
// fn fromMyFileInfo(src: *structs.MyFileInfo, dst: *c.fuse_file_info) void
// {
//     c.myfuse_file_info_set(src, &dst.flags, &dst.padding, &dst.fh,
//             &dst.lock_owner, &dst.poll_events, &dst.backing_id,
//             &dst.compat_flags);
// }

//*****************************************************************************
fn toMyStat(src: *c.struct_stat, dst: *structs.MyStat) void
{
    dst.st_dev = src.st_dev;
    dst.st_ino = src.st_ino;
    dst.st_nlink = src.st_nlink;
    dst.st_mode = src.st_mode;
    dst.st_uid = src.st_uid;
    dst.st_gid = src.st_gid;
    dst.st_rdev = src.st_rdev;
    dst.st_size = src.st_size;
    dst.st_blksize = src.st_blksize;
    dst.st_blocks = src.st_blocks;
    dst.st_atim_tv_sec = src.st_atim.tv_sec;
    dst.st_atim_tv_nsec = src.st_atim.tv_nsec;
    dst.st_mtim_tv_sec = src.st_mtim.tv_sec;
    dst.st_mtim_tv_nsec = src.st_mtim.tv_nsec;
    dst.st_ctim_tv_sec = src.st_ctim.tv_sec;
    dst.st_ctim_tv_nsec = src.st_ctim.tv_nsec;
}

//*****************************************************************************
fn fromMyStat(src: *structs.MyStat, dst: *c.struct_stat) void
{
    dst.st_dev = src.st_dev;
    dst.st_ino = src.st_ino;
    dst.st_nlink = src.st_nlink;
    dst.st_mode = src.st_mode;
    dst.st_uid = src.st_uid;
    dst.st_gid = src.st_gid;
    dst.st_rdev = src.st_rdev;
    dst.st_size = src.st_size;
    dst.st_blksize = src.st_blksize;
    dst.st_blocks = src.st_blocks;
    dst.st_atim.tv_sec = src.st_atim_tv_sec;
    dst.st_atim.tv_nsec = src.st_atim_tv_nsec;
    dst.st_mtim.tv_sec = src.st_mtim_tv_sec;
    dst.st_mtim.tv_nsec = src.st_mtim_tv_nsec;
    dst.st_ctim.tv_sec = src.st_ctim_tv_sec;
    dst.st_ctim.tv_nsec = src.st_ctim_tv_nsec;
}

//*****************************************************************************
fn toMyEntryParam(src: *c.struct_fuse_entry_param, dst: *structs.MyEntryParam) void
{
    dst.ino = src.ino;
    dst.generation = src.generation;
    toMyStat(&src.stat, &dst.stat);
    dst.attr_timeout = src.attr_timeout;
    dst.entry_timeout = src.entry_timeout;
}

//*****************************************************************************
fn fromMyEntryParam(src: *structs.MyEntryParam, dst: *c.struct_fuse_entry_param) void
{
    dst.ino = src.ino;
    dst.generation = src.generation;
    fromMyStat(&src.attr, &dst.attr);
    dst.attr_timeout = src.attr_timeout;
    dst.entry_timeout = src.entry_timeout;
}

//*****************************************************************************
fn fromMyStatVfs(src: *structs.MyStatVfs, dst: *c.struct_statvfs) void
{
    dst.f_bsize = src.f_bsize;
    dst.f_frsize = src.f_frsize;
    dst.f_blocks = src.f_blocks;
    dst.f_bfree = src.f_bfree;
    dst.f_bavail = src.f_bavail;
    dst.f_files = src.f_files;
    dst.f_ffree = src.f_ffree;
    dst.f_favail = src.f_favail;
    dst.f_fsid = src.f_fsid;
    dst.f_flag = src.f_flag;
    dst.f_namemax = src.f_namemax;
    //dst.f_type = src.f_type;
}

//*****************************************************************************
export fn cb_lookup(req: c.fuse_req_t, parent: c.fuse_ino_t,
        name: ?[*:0]const u8) void
{
    const user = c.fuse_req_userdata(req);
    if (user) |auser|
    {
        const lfs: *fuse_session_t = @alignCast(@ptrCast(auser));
        return lfs.lookup(req, parent, name)
                catch |err| cb_error(@src(), err);
    }
    _ = c.fuse_reply_err(req, c.ENOENT);
}

//*****************************************************************************
export fn cb_readdir(req: c.fuse_req_t, ino: c.fuse_ino_t, size: usize,
        off: c.off_t, fi: ?*c.fuse_file_info) void
{
    const user = c.fuse_req_userdata(req);
    if (user) |auser|
    {
        const lfs: *fuse_session_t = @alignCast(@ptrCast(auser));
        return lfs.readdir(req, ino, size, off, fi)
                catch |err| cb_error(@src(), err);
    }
    _ = c.fuse_reply_err(req, c.ENOENT);
}

//*****************************************************************************
export fn cb_mkdir(req: c.fuse_req_t, parent: c.fuse_ino_t,
        name: ?[*:0]const u8, mode: c.mode_t) void
{
    const user = c.fuse_req_userdata(req);
    if (user) |auser|
    {
        const lfs: *fuse_session_t = @alignCast(@ptrCast(auser));
        return lfs.mkdir(req, parent, name, mode)
                catch |err| cb_error(@src(), err);
    }
    _ = c.fuse_reply_err(req, c.ENOENT);
}

//*****************************************************************************
export fn cb_rmdir(req: c.fuse_req_t, parent: c.fuse_ino_t,
        name: ?[*:0]const u8) void
{
    const user = c.fuse_req_userdata(req);
    if (user) |auser|
    {
        const lfs: *fuse_session_t = @alignCast(@ptrCast(auser));
        return lfs.rmdir(req, parent, name)
                catch |err| cb_error(@src(), err);
    }
    _ = c.fuse_reply_err(req, c.ENOENT);
}

//*****************************************************************************
export fn cb_unlink(req: c.fuse_req_t, parent: c.fuse_ino_t,
        name: ?[*:0]const u8) void
{
    const user = c.fuse_req_userdata(req);
    if (user) |auser|
    {
        const lfs: *fuse_session_t = @alignCast(@ptrCast(auser));
        return lfs.unlink(req, parent, name)
                catch |err| cb_error(@src(), err);
    }
    _ = c.fuse_reply_err(req, c.ENOENT);
}

//*****************************************************************************
export fn cb_rename(req: c.fuse_req_t,
        old_parent: c.fuse_ino_t, old_name: ?[*:0]const u8,
        new_parent: c.fuse_ino_t, new_name: ?[*:0]const u8, flags: c_uint) void
{
    const user = c.fuse_req_userdata(req);
    if (user) |auser|
    {
        const lfs: *fuse_session_t = @alignCast(@ptrCast(auser));
        return lfs.rename(req, old_parent, old_name, new_parent, new_name, flags)
                catch |err| cb_error(@src(), err);
    }
    _ = c.fuse_reply_err(req, c.ENOENT);
}

//*****************************************************************************
export fn cb_open(req: c.fuse_req_t, ino: c.fuse_ino_t,
        fi: ?*c.fuse_file_info) void
{
    const user = c.fuse_req_userdata(req);
    if (user) |auser|
    {
        const lfs: *fuse_session_t = @alignCast(@ptrCast(auser));
        return lfs.open(req, ino, fi)
                catch |err| cb_error(@src(), err);
    }
    _ = c.fuse_reply_err(req, c.ENOENT);
}

//*****************************************************************************
export fn cb_release(req: c.fuse_req_t, ino: c.fuse_ino_t,
        fi: ?*c.fuse_file_info) void
{
    const user = c.fuse_req_userdata(req);
    if (user) |auser|
    {
        const lfs: *fuse_session_t = @alignCast(@ptrCast(auser));
        return lfs.release(req, ino, fi)
                catch |err| cb_error(@src(), err);
    }
    _ = c.fuse_reply_err(req, c.ENOENT);
}

//*****************************************************************************
export fn cb_read(req: c.fuse_req_t, ino: c.fuse_ino_t, size: usize,
        off: c.off_t, fi: ?*c.fuse_file_info) void
{
    const user = c.fuse_req_userdata(req);
    if (user) |auser|
    {
        const lfs: *fuse_session_t = @alignCast(@ptrCast(auser));
        return lfs.read(req, ino, size, off, fi)
                catch |err| cb_error(@src(), err);
    }
    _ = c.fuse_reply_err(req, c.ENOENT);
}

//*****************************************************************************
export fn cb_write(req: c.fuse_req_t, ino: c.fuse_ino_t, buf: ?[*]const u8,
        size: usize, off: c.off_t, fi: ?*c.fuse_file_info) void
{
    const user = c.fuse_req_userdata(req);
    if (user) |auser|
    {
        const lfs: *fuse_session_t = @alignCast(@ptrCast(auser));
        return lfs.write(req, ino, buf, size, off, fi)
                catch |err| cb_error(@src(), err);
    }
    _ = c.fuse_reply_err(req, c.ENOENT);
}

//*****************************************************************************
export fn cb_create(req: c.fuse_req_t, parent: c.fuse_ino_t,
        name: ?[*:0]const u8, mode: c.mode_t, fi: ?*c.fuse_file_info) void
{
    const user = c.fuse_req_userdata(req);
    if (user) |auser|
    {
        const lfs: *fuse_session_t = @alignCast(@ptrCast(auser));
        return lfs.create(req, parent, name, mode, fi)
                catch |err| cb_error(@src(), err);
    }
    _ = c.fuse_reply_err(req, c.ENOENT);
}

//*****************************************************************************
export fn cb_fsync(req: c.fuse_req_t, ino: c.fuse_ino_t, datasync: c_int,
        fi: ?*c.fuse_file_info) void
{
    const user = c.fuse_req_userdata(req);
    if (user) |auser|
    {
        const lfs: *fuse_session_t = @alignCast(@ptrCast(auser));
        return lfs.fsync(req, ino, datasync, fi)
                catch |err| cb_error(@src(), err);
    }
    _ = c.fuse_reply_err(req, c.ENOENT);
}

//*****************************************************************************
export fn cb_getattr(req: c.fuse_req_t, ino: c.fuse_ino_t,
        fi: ?*c.fuse_file_info) void
{
    const user = c.fuse_req_userdata(req);
    if (user) |auser|
    {
        const lfs: *fuse_session_t = @alignCast(@ptrCast(auser));
        return lfs.getattr(req, ino, fi)
                catch |err| cb_error(@src(), err);
    }
    _ = c.fuse_reply_err(req, c.ENOENT);
}

//*****************************************************************************
export fn cb_setattr(req: c.fuse_req_t, ino: c.fuse_ino_t,
        attr: ?*c.struct_stat, to_set: c_int, fi: ?*c.fuse_file_info) void
{
    const user = c.fuse_req_userdata(req);
    if (user) |auser|
    {
        const lfs: *fuse_session_t = @alignCast(@ptrCast(auser));
        return lfs.setattr(req, ino, attr, to_set, fi)
                catch |err| cb_error(@src(), err);
    }
    _ = c.fuse_reply_err(req, c.ENOENT);
}

//*****************************************************************************
export fn cb_opendir(req: c.fuse_req_t, ino: c.fuse_ino_t,
        fi: ?*c.fuse_file_info) void
{
    const user = c.fuse_req_userdata(req);
    if (user) |auser|
    {
        const lfs: *fuse_session_t = @alignCast(@ptrCast(auser));
        return lfs.opendir(req, ino, fi)
                catch |err| cb_error(@src(), err);
    }
    _ = c.fuse_reply_err(req, c.ENOENT);
}

//*****************************************************************************
export fn cb_releasedir(req: c.fuse_req_t, ino: c.fuse_ino_t,
        fi: ?*c.fuse_file_info) void
{
    const user = c.fuse_req_userdata(req);
    if (user) |auser|
    {
        const lfs: *fuse_session_t = @alignCast(@ptrCast(auser));
        return lfs.releasedir(req, ino, fi) catch |err| cb_error(@src(), err);
    }
    _ = c.fuse_reply_err(req, c.ENOENT);
}

//*****************************************************************************
export fn cb_statfs(req: c.fuse_req_t, ino: c.fuse_ino_t) void
{
    const user = c.fuse_req_userdata(req);
    if (user) |auser|
    {
        const lfs: *fuse_session_t = @alignCast(@ptrCast(auser));
        return lfs.statfs(req, ino) catch |err| cb_error(@src(), err);
    }
    _ = c.fuse_reply_err(req, c.ENOENT);
}
