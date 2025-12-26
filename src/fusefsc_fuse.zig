const std = @import("std");
const builtin = @import("builtin");
const log = @import("log");
const fusefsc = @import("fusefsc.zig");
const c = @cImport(
{
    @cDefine("FUSE_USE_VERSION", "29");
    @cInclude("fuse_lowlevel.h");
});
