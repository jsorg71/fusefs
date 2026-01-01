const std = @import("std");
const builtin = @import("builtin");
const log = @import("log");
const fusefsc = @import("fusefsc.zig");
const c = @cImport(
{
    @cDefine("FUSE_USE_VERSION", "35");
    @cInclude("fuse_lowlevel.h");
    @cInclude("myfuse.h");
});

pub const FuseError = error
{
    FuseMountFailed,
    FuseNewFailed,
    FuseAllocFailed,
    FuseOtherFailed,
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
fn cb_error_int(src: std.builtin.SourceLocation, err: anyerror, rv: c_int) c_int
{
    log.logln(log.LogLevel.info, src, "error[{}]", .{err}) catch return rv;
    return rv;
}

pub const fuse_session_t = struct
{
    mi: ?*anyopaque = null,

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
    }

    //*************************************************************************
    pub fn get_fds(self: *fuse_session_t, rfds: []i32, num_rfds: *usize,
            wfds: []i32, num_wfds: *usize, timeout: *i32) !void
    {
        const rv = c.myfuse_get_fds(self.mi, rfds.ptr, num_rfds,
                wfds.ptr, num_wfds, timeout);
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
    pub fn lookup(self: *fuse_session_t, req: c.fuse_req_t,
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
        _ = c.fuse_reply_err(req, 2);
    }

    //*************************************************************************
    pub fn opendir(self: *fuse_session_t, req: c.fuse_req_t, ino: c.fuse_ino_t,
            fi: ?*c.fuse_file_info) !void
    {
        if (req) |areq|
        {
            try log.logln(log.LogLevel.info, @src(),
                    "self [0x{X}] req [0x{X}] ino [0x{X}] fi [0x{X}]",
                    .{@intFromPtr(self), @intFromPtr(areq), ino, @intFromPtr(fi)});
        }
        _ = c.fuse_reply_err(req, 2);
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
        return lfs.lookup(req, parent, name) catch |err| cb_error(@src(), err);
    }
    _ = c.fuse_reply_err(req, 2);
}

//*****************************************************************************
export fn cb_readdir(req: c.fuse_req_t, ino: c.fuse_ino_t, size: usize,
        off: c.off_t, fi: ?*c.fuse_file_info) void
{
    _ = ino;
    _ = size;
    _ = off;
    _ = fi;
    _ = c.fuse_reply_err(req, 2);
}

//*****************************************************************************
export fn cb_mkdir(req: c.fuse_req_t, parent: c.fuse_ino_t,
        name: ?[*:0]const u8, mode: c.mode_t) void
{
    _ = parent;
    _ = name;
    _ = mode;
    _ = c.fuse_reply_err(req, 2);
}

//*****************************************************************************
export fn cb_rmdir(req: c.fuse_req_t, parent: c.fuse_ino_t,
        name: ?[*:0]const u8) void
{
    _ = parent;
    _ = name;
    _ = c.fuse_reply_err(req, 2);
}

//*****************************************************************************
export fn cb_unlink(req: c.fuse_req_t, parent: c.fuse_ino_t,
        name: ?[*:0]const u8) void
{
    _ = parent;
    _ = name;
    _ = c.fuse_reply_err(req, 2);
}

//*****************************************************************************
export fn cb_rename(req: c.fuse_req_t,
        old_parent: c.fuse_ino_t, old_name: ?[*:0]const u8,
        new_parent: c.fuse_ino_t, new_name: ?[*:0]const u8, flags: c_uint) void
{
    _ = old_parent;
    _ = old_name;
    _ = new_parent;
    _ = new_name;
    _ = flags;
    _ = c.fuse_reply_err(req, 2);
}

//*****************************************************************************
export fn cb_open(req: c.fuse_req_t, ino: c.fuse_ino_t,
        fi: ?*c.fuse_file_info) void
{
    _ = ino;
    _ = fi;
    _ = c.fuse_reply_err(req, 2);
}

//*****************************************************************************
export fn cb_release(req: c.fuse_req_t, ino: c.fuse_ino_t,
        fi: ?*c.fuse_file_info) void
{
    _ = ino;
    _ = fi;
    _ = c.fuse_reply_err(req, 2);
}

//*****************************************************************************
export fn cb_read(req: c.fuse_req_t, ino: c.fuse_ino_t, size: usize,
        off: c.off_t, fi: ?*c.fuse_file_info) void
{
    _ = ino;
    _ = size;
    _ = off;
    _ = fi;
    _ = c.fuse_reply_err(req, 2);
}

//*****************************************************************************
export fn cb_write(req: c.fuse_req_t, ino: c.fuse_ino_t, buf: ?[*]const u8,
        size: usize, off: c.off_t, fi: ?*c.fuse_file_info) void
{
    _ = ino;
    _ = buf;
    _ = size;
    _ = off;
    _ = fi;
    _ = c.fuse_reply_err(req, 2);
}

//*****************************************************************************
export fn cb_create(req: c.fuse_req_t, parent: c.fuse_ino_t,
        name: ?[*:0]const u8, mode: c.mode_t, fi: ?*c.fuse_file_info) void
{
    _ = parent;
    _ = name;
    _ = mode;
    _ = fi;
    _ = c.fuse_reply_err(req, 2);
}

//*****************************************************************************
export fn cb_fsync(req: c.fuse_req_t, ino: c.fuse_ino_t, datasync: c_int,
        fi: ?*c.fuse_file_info) void
{
    _ = ino;
    _ = datasync;
    _ = fi;
    _ = c.fuse_reply_err(req, 2);
}

//*****************************************************************************
export fn cb_getattr(req: c.fuse_req_t, ino: c.fuse_ino_t,
        fi: ?*c.fuse_file_info) void
{
    _ = ino;
    _ = fi;
    _ = c.fuse_reply_err(req, 2);
}

//*****************************************************************************
export fn cb_setattr(req: c.fuse_req_t, ino: c.fuse_ino_t,
        attr: ?*c.struct_stat, to_set: c_int, fi: ?*c.fuse_file_info) void
{
    _ = ino;
    _ = attr;
    _ = to_set;
    _ = fi;
    _ = c.fuse_reply_err(req, 2);
}

//*****************************************************************************
export fn cb_opendir(req: c.fuse_req_t, ino: c.fuse_ino_t,
        fi: ?*c.fuse_file_info) void
{
    const user = c.fuse_req_userdata(req);
    if (user) |auser|
    {
        const lfs: *fuse_session_t = @alignCast(@ptrCast(auser));
        return lfs.opendir(req, ino, fi) catch |err| cb_error(@src(), err);
    }
    _ = c.fuse_reply_err(req, 2);
}

//*****************************************************************************
export fn cb_releasedir(req: c.fuse_req_t, ino: c.fuse_ino_t,
        fi: ?*c.fuse_file_info) void
{
    _ = ino;
    _ = fi;
    _ = c.fuse_reply_err(req, 2);
}

//*****************************************************************************
export fn cb_statfs(req: c.fuse_req_t, ino: c.fuse_ino_t) void
{
    _ = ino;
    _ = c.fuse_reply_err(req, 2);
}
