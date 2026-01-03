const std = @import("std");
const builtin = @import("builtin");
const log = @import("log");
const parse = @import("parse");
const fusefsc = @import("fusefsc.zig");
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
};

const out_data_t = struct
{
    size: usize = 0,
    sent: usize = 0,
    sout: *parse.parse_t,
    next: ?*out_data_t = null,
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

pub const fuse_session_t = struct
{
    mi: ?*anyopaque = null,
    out_head: ?*out_data_t = null,
    out_tail: ?*out_data_t = null,

    //*************************************************************************
    pub fn init(self: *fuse_session_t) !void
    {
        self.* = .{};
        const rv = c.myfuse_create("/home/jay/test_mount", self, &self.mi);
        try log.logln(log.LogLevel.info, @src(), "myfuse_create rv {}", .{rv});
        return switch (rv)
        {
            0 => {},
            1 => FuseError.FuseAllocFailed,
            2 => FuseError.FuseNewFailed,
            3 => FuseError.FuseMountFailed,
            else => FuseError.FuseOtherFailed,
        };
    }

    //*************************************************************************
    pub fn deinit(self: *fuse_session_t) void
    {
        log.logln(log.LogLevel.info, @src(), "", .{}) catch return;
        _ = c.myfuse_delete(self.mi);
        // delete any not sent messages
        while (self.out_head) |aout_head|
        {
            //log.logln(log.LogLevel.info, @src(), "cleanup item", .{}) catch return;
            self.out_head = aout_head.next;
            //_ = c.fuse_reply_err(req, c.ENOENT);
            aout_head.sout.delete();
            g_allocator.destroy(aout_head);
        }
    }

    //*************************************************************************
    pub fn get_fds(self: *fuse_session_t,
            rfds: []i32, num_rfds: *usize,
            wfds: []i32, num_wfds: *usize,
            timeout: *i32) !void
    {
        const rv = c.myfuse_get_fds(self.mi,
                rfds.ptr, rfds.len, num_rfds,
                wfds.ptr, wfds.len, num_wfds,
                timeout);
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
    // * Valid replies:
    // *   fuse_reply_entry
    // *   fuse_reply_err
    fn lookup(self: *fuse_session_t, req: c.fuse_req_t,
            parent: c.fuse_ino_t, name: ?[*:0]const u8) !void
    {
        if (req) |areq|
        {
            if (name) |aname|
            {
                const str = std.mem.sliceTo(aname, 0);
                try log.logln(log.LogLevel.info, @src(),
                        "self [0x{X}] req [0x{X}] parent [0x{X}] name [{s}]",
                        .{@intFromPtr(self), @intFromPtr(areq), parent, str});
            }
        }
        _ = c.fuse_reply_err(req, c.ENOENT);
    }

    //*************************************************************************
    // * Valid replies:
    // *   fuse_reply_open
    // *   fuse_reply_err
    fn readdir(self: *fuse_session_t, req: c.fuse_req_t, ino: c.fuse_ino_t,
            size: usize, off: c.off_t, fi: ?*c.fuse_file_info) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        _ = self;
        _ = ino;
        _ = size;
        _ = off;
        _ = fi;
        _ = c.fuse_reply_err(req, c.ENOENT);
    }

    //*************************************************************************
    // * Valid replies:
    // *   fuse_reply_entry
    // *   fuse_reply_err
    fn mkdir(self: *fuse_session_t, req: c.fuse_req_t, parent: c.fuse_ino_t,
            name: ?[*:0]const u8, mode: c.mode_t) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        _ = self;
        _ = parent;
        _ = name;
        _ = mode;
        _ = c.fuse_reply_err(req, c.ENOENT);
    }

    //*************************************************************************
    // * Valid replies:
    // *   fuse_reply_err
    fn rmdir(self: *fuse_session_t, req: c.fuse_req_t, parent: c.fuse_ino_t,
            name: ?[*:0]const u8) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        _ = self;
        _ = parent;
        _ = name;
        _ = c.fuse_reply_err(req, c.ENOENT);
    }

    //*************************************************************************
    // * Valid replies:
    // *   fuse_reply_err
    fn unlink(self: *fuse_session_t, req: c.fuse_req_t, parent: c.fuse_ino_t,
            name: ?[*:0]const u8) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        _ = self;
        _ = parent;
        _ = name;
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
        _ = self;
        _ = old_parent;
        _ = old_name;
        _ = new_parent;
        _ = new_name;
        _ = flags;
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
        _ = self;
        _ = ino;
        _ = fi;
        _ = c.fuse_reply_err(req, c.ENOENT);
    }

    //*************************************************************************
    // * Valid replies:
    // *   fuse_reply_err
    fn release(self: *fuse_session_t, req: c.fuse_req_t, ino: c.fuse_ino_t,
            fi: ?*c.fuse_file_info) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        _ = self;
        _ = ino;
        _ = fi;
        _ = c.fuse_reply_err(req, c.ENOENT);
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
        _ = self;
        _ = ino;
        _ = size;
        _ = off;
        _ = fi;
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
        _ = self;
        _ = ino;
        _ = buf;
        _ = size;
        _ = off;
        _ = fi;
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
        _ = self;
        _ = parent;
        _ = name;
        _ = mode;
        _ = fi;
        _ = c.fuse_reply_err(req, c.ENOENT);
    }

    //*************************************************************************
    // * Valid replies:
    // *   fuse_reply_err
    fn fsync(self: *fuse_session_t, req: c.fuse_req_t, ino: c.fuse_ino_t,
            datasync: c_int, fi: ?*c.fuse_file_info) !void
    {
        try log.logln(log.LogLevel.info, @src(), "", .{});
        _ = self;
        _ = ino;
        _ = datasync;
        _ = fi;
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
        _ = self;
        _ = ino;
        _ = fi;
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
        _ = self;
        _ = ino;
        _ = attr;
        _ = to_set;
        _ = fi;
        _ = c.fuse_reply_err(req, c.ENOENT);

    }

    //*************************************************************************
    // * Valid replies:
    // *   fuse_reply_open
    // *   fuse_reply_err
    fn opendir(self: *fuse_session_t, req: c.fuse_req_t, ino: c.fuse_ino_t,
            fi: ?*c.fuse_file_info) !void
    {
        if (req) |areq|
        {
            if (fi) |afi|
            {
                const mfi: *c.myfuse_file_info = @alignCast(@ptrCast(afi));
                try log.logln(log.LogLevel.info, @src(),
                        "self [0x{X}] req [0x{X}] ino [0x{X}] mfi.flags [0x{X}]",
                        .{@intFromPtr(self), @intFromPtr(areq), ino,
                        mfi.flags});
                const sout = try parse.parse_t.create(&g_allocator, 128);
                errdefer sout.delete();
                // header, skip and set later
                try sout.check_rem(4);
                sout.push_layer(4, 0);
                // req, ino
                try sout.check_rem(16);
                sout.out_u64_le(@intFromPtr(areq));
                sout.out_u64_le(ino);
                // fuse_file_info
                try sout.check_rem(64);
                sout.out_i32_le(mfi.flags);
                sout.out_u32_le(mfi.padding);
                sout.out_u32_le(mfi.padding2);
                sout.out_u32_le(mfi.padding3);
                sout.out_u64_le(mfi.fh);
                sout.out_u64_le(mfi.lock_owner);
                sout.out_u32_le(mfi.poll_events);
                sout.out_i32_le(mfi.backing_id);
                sout.out_u64_le(mfi.compat_flags);
                sout.out_u64_le(mfi.reserved[0]);
                sout.out_u64_le(mfi.reserved[1]);
                sout.push_layer(0, 1);
                sout.pop_layer(0);
                // header
                sout.out_u16_le(15); // code
                const size = sout.layer_subtract(1, 0);
                sout.out_u16_le(size);
                // add to linked list
                const out_data = try g_allocator.create(out_data_t);
                errdefer g_allocator.destroy(out_data);
                out_data.* = .{.sout = sout, .size = size};
                if (self.out_tail) |aout_tail|
                {
                    aout_tail.next = out_data;
                    self.out_tail = out_data;
                }
                else
                {
                    self.out_head = out_data;
                    self.out_tail = out_data;
                }
                return;
            }
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
        _ = self;
        _ = ino;
        _ = fi;
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
        _ = self;
        _ = ino;
        _ = c.fuse_reply_err(req, c.ENOENT);

    }

};

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
        if (lfs.opendir(req, ino, fi)) |_|
        {
            return;
        }
        else |err|
        {
            cb_error(@src(), err);
        }
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
