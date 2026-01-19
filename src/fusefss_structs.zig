const std = @import("std");
const builtin = @import("builtin");
const log = @import("log");
const hexdump = @import("hexdump");
const parse = @import("parse");
const git = @import("git.zig");
const toml = @import("fusefss_toml.zig");
const net = std.net;
const posix = std.posix;

var g_allocator: std.mem.Allocator = std.heap.c_allocator;

pub const MyFuseMsg = enum(u16)
{
    lookup      = 1,
    readdir     = 2,
    mkdir       = 3,
    rmdir       = 4,
    unlink      = 5,
    rename      = 6,
    open        = 7,
    release     = 8,
    read        = 9,
    write       = 10,
    create      = 11,
    fsync       = 12,
    getattr     = 13,
    setattr     = 14,
    opendir     = 15,
    releasedir  = 16,
    statfs      = 17,
};

pub const MyFuseReplyMsg = enum(u16)
{
    statfs      = 1,
    attr        = 2,
    create      = 3,
    write       = 4,
    buf         = 5,
    buf_dir     = 105,
    iov         = 6,
    data        = 7,
    open        = 8,
    entry       = 9,
    err         = 10,
    end         = 11,
};

pub const dir_item = struct
{
    ino: u64 = 0,
    mode: u32 = 0,
    name: [] const u8 = &.{},
};

pub const MyFileInfo = struct
{
    flags: i32 = 0,
    padding: u32 = 0,
    padding2: u32 = 0,
    padding3: u32 = 0,
    fh: u64 = 0,
    lock_owner: u64 = 0,
    poll_events: u32 = 0,
    backing_id: i32 = 0,
    compat_flags: u64 = 0,
    reserved: [2]u64 = .{0, 0},

    //*************************************************************************
    pub fn in(self: *MyFileInfo, sin: *parse.parse_t) !void
    {
        try sin.check_rem(4 * 4 + 2 * 8 + 2 * 4 + 3 * 8); // 64
        self.flags = sin.in_i32_le();
        self.padding = sin.in_u32_le();
        self.padding2 = sin.in_u32_le();
        self.padding3 = sin.in_u32_le();
        self.fh = sin.in_u64_le();
        self.lock_owner = sin.in_u64_le();
        self.poll_events = sin.in_u32_le();
        self.backing_id = sin.in_i32_le();
        self.compat_flags = sin.in_u64_le();
        self.reserved[0] = sin.in_u64_le();
        self.reserved[1] = sin.in_u64_le();
    }

    //*************************************************************************
    pub fn out(self: *MyFileInfo, sout: *parse.parse_t) !void
    {
        try sout.check_rem(4 * 4 + 2 * 8 + 2 * 4 + 3 * 8); // 64
        sout.out_i32_le(self.flags);
        sout.out_u32_le(self.padding);
        sout.out_u32_le(self.padding2);
        sout.out_u32_le(self.padding3);
        sout.out_u64_le(self.fh);
        sout.out_u64_le(self.lock_owner);
        sout.out_u32_le(self.poll_events);
        sout.out_i32_le(self.backing_id);
        sout.out_u64_le(self.compat_flags);
        sout.out_u64_le(self.reserved[0]);
        sout.out_u64_le(self.reserved[1]);
    }

};

pub const MyStat = struct 
{
    st_dev: u64 = 0,
    st_ino: u64 = 0,
    st_nlink: u32 = 0,
    st_mode: u32 = 0,
    st_uid: u32 = 0,
    st_gid: u32 = 0,
    st_rdev: u64 = 0,
    st_size: i64 = 0,
    st_blksize: i64 = 0,
    st_blocks: i64 = 0,
    st_atim_tv_sec: i64 = 0,
    st_atim_tv_nsec: i64 = 0,
    st_mtim_tv_sec: i64 = 0,
    st_mtim_tv_nsec: i64 = 0,
    st_ctim_tv_sec: i64 = 0,
    st_ctim_tv_nsec: i64 = 0,

    //*************************************************************************
    pub fn in(self: *MyStat, sin: *parse.parse_t) !void
    {
        try sin.check_rem(3 * 8 + 3 * 4 + 10 * 8); // 116
        self.st_dev = sin.in_u64_le();
        self.st_ino = sin.in_u64_le();
        self.st_nlink = sin.in_u32_le();
        self.st_mode = sin.in_u32_le();
        self.st_uid = sin.in_u32_le();
        self.st_gid = sin.in_u32_le();
        self.st_rdev = sin.in_u64_le();
        self.st_size = sin.in_i64_le();
        self.st_blksize = sin.in_i64_le();
        self.st_blocks = sin.in_i64_le();
        self.st_atim_tv_sec = sin.in_i64_le();
        self.st_atim_tv_nsec = sin.in_i64_le();
        self.st_mtim_tv_sec = sin.in_i64_le();
        self.st_mtim_tv_nsec = sin.in_i64_le();
        self.st_ctim_tv_sec = sin.in_i64_le();
        self.st_ctim_tv_nsec = sin.in_i64_le();
    }

    //*************************************************************************
    pub fn out(self: *MyStat, sout: *parse.parse_t) !void
    {
        try sout.check_rem(3 * 8 + 3 * 4 + 10 * 8); // 116
        sout.out_u64_le(self.st_dev);
        sout.out_u64_le(self.st_ino);
        sout.out_u32_le(self.st_nlink);
        sout.out_u32_le(self.st_mode);
        sout.out_u32_le(self.st_uid);
        sout.out_u32_le(self.st_gid);
        sout.out_u64_le(self.st_rdev);
        sout.out_i64_le(self.st_size);
        sout.out_i64_le(self.st_blksize);
        sout.out_i64_le(self.st_blocks);
        sout.out_i64_le(self.st_atim_tv_sec);
        sout.out_i64_le(self.st_atim_tv_nsec);
        sout.out_i64_le(self.st_mtim_tv_sec);
        sout.out_i64_le(self.st_mtim_tv_nsec);
        sout.out_i64_le(self.st_ctim_tv_sec);
        sout.out_i64_le(self.st_ctim_tv_nsec);
    }

};

pub const MyEntryParam = struct
{
    ino: u64 = 0,
    generation: u64 = 0,
    attr: MyStat = .{},
    attr_timeout: f64 = 0.0,
    entry_timeout: f64 = 0.0,

    //*************************************************************************
    pub fn in(self: *MyEntryParam, sin: *parse.parse_t) !void
    {
        try sin.check_rem(16);
        self.ino = sin.in_u64_le();
        self.generation = sin.in_u64_le();
        try self.attr.in(sin);
        try sin.check_rem(16);
        self.attr_timeout = sin.in_f64_le();
        self.entry_timeout = sin.in_f64_le();
    }

    //*************************************************************************
    pub fn out(self: *MyEntryParam, sout: *parse.parse_t) !void
    {
        try sout.check_rem(16);
        sout.out_u64_le(self.ino);
        sout.out_u64_le(self.generation);
        try self.attr.out(sout);
        try sout.check_rem(16);
        sout.out_f64_le(self.attr_timeout);
        sout.out_f64_le(self.entry_timeout);
    }

};

pub const MyStatVfs = struct
{
    f_bsize: u64 = 0,
    f_frsize: u64 = 0,
    f_blocks: u64 = 0,
    f_bfree: u64 = 0,
    f_bavail: u64 = 0,
    f_files: u64 = 0,
    f_ffree: u64 = 0,
    f_favail: u64 = 0,
    f_fsid: u64 = 0,
    f_flag: u64 = 0,
    f_namemax: u64 = 0,
    f_type: u32 = 0,

    //*************************************************************************
    pub fn in(self: *MyStatVfs, sin: *parse.parse_t) !void
    {
        try sin.check_rem(11 * 8 + 4); // 92
        self.f_bsize = sin.in_u64_le();
        self.f_frsize = sin.in_u64_le();
        self.f_blocks = sin.in_u64_le();
        self.f_bfree = sin.in_u64_le();
        self.f_bavail = sin.in_u64_le();
        self.f_files = sin.in_u64_le();
        self.f_ffree = sin.in_u64_le();
        self.f_favail = sin.in_u64_le();
        self.f_fsid = sin.in_u64_le();
        self.f_flag = sin.in_u64_le();
        self.f_namemax = sin.in_u64_le();
        self.f_type = sin.in_u32_le();
    }

    //*************************************************************************
    pub fn out(self: *MyStatVfs, sout: *parse.parse_t) !void
    {
        try sout.check_rem(11 * 8 + 4); // 92
        sout.out_u64_le(self.f_bsize);
        sout.out_u64_le(self.f_frsize);
        sout.out_u64_le(self.f_blocks);
        sout.out_u64_le(self.f_bfree);
        sout.out_u64_le(self.f_bavail);
        sout.out_u64_le(self.f_files);
        sout.out_u64_le(self.f_ffree);
        sout.out_u64_le(self.f_favail);
        sout.out_u64_le(self.f_fsid);
        sout.out_u64_le(self.f_flag);
        sout.out_u64_le(self.f_namemax);
        sout.out_u32_le(self.f_type);
    }

};

const expect = std.testing.expect;

//*****************************************************************************
test "f64_to_f64"
{
    //const s = parse.parse_t.create(std.heap.DebugAllocator, 1024);
    //defer s.delete();
    const valf64: f64 = 10.789;
    const valf64_array = std.mem.toBytes(valf64);
    std.debug.print("type {}\n", .{@TypeOf(valf64_array)});
    const valf64a = std.mem.bytesAsValue(f64, &valf64_array).*;
    try expect(valf64 == valf64a);
}
