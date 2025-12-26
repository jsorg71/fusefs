const std = @import("std");
const builtin = @import("builtin");
const log = @import("log");
const fusefss = @import("fusefss.zig");
const c = @cImport(
{
    @cInclude("toml.h");
});

pub const TomlError = error
{
    FileSizeChanged,
    TomlParseFailed,
    TomlTableInFailed,
};

var g_allocator: *const std.mem.Allocator = undefined;
const g_error_buf_size: usize = 1024;

//*****************************************************************************
inline fn err_if(b: bool, err: TomlError) !void
{
    if (b) return err else return;
}

//*****************************************************************************
fn load_fusefss_config(file_name: []const u8) !*c.toml_table_t
{
    var file = try std.fs.cwd().openFile(file_name, .{});
    defer file.close();
    const file_stat = try file.stat();
    const file_size: usize = @intCast(file_stat.size);

    var buf = try g_allocator.alloc(u8, file_size + 1);
    defer g_allocator.free(buf);
    const buf1 = try g_allocator.alloc(u8, file_size + 1);
    defer g_allocator.free(buf1);

    var bytes_read: usize = 0;
    if ((builtin.zig_version.major == 0) and
            (builtin.zig_version.minor < 15))
    {
        var file_reader = std.io.bufferedReader(file.reader());
        var reader = file_reader.reader();
        bytes_read = try reader.read(buf);
    }
    else
    {
        var file_reader = file.reader(buf1);
        const reader = &file_reader.interface;
        bytes_read = try reader.readSliceShort(buf);
    }

    var errbuf: []u8 = undefined;
    errbuf = try g_allocator.alloc(u8, g_error_buf_size);
    defer g_allocator.free(errbuf);

    try log.logln(log.LogLevel.info, @src(),
            "file_size {} bytes read {}", .{file_size, bytes_read});
    try err_if(bytes_read > file_size, TomlError.FileSizeChanged);
    buf[bytes_read] = 0;
    const table = c.toml_parse(buf.ptr, errbuf.ptr, g_error_buf_size);
    if (table) |atable|
    {
        return atable;
    }
    try log.logln(log.LogLevel.info, @src(), 
            "toml_parse failed errbuf {s}", .{errbuf});
    return TomlError.TomlParseFailed;
}

//*****************************************************************************
pub fn setup_fusefss_info(allocator: *const std.mem.Allocator,
        info: *fusefss.fusefss_info_t, config_file: []const u8) !void
{
    try log.logln(log.LogLevel.info, @src(),
            "config file [{s}]", .{config_file});
    g_allocator = allocator;
    const table = try load_fusefss_config(config_file);
    defer c.toml_free(table);
    try log.logln(log.LogLevel.info, @src(),
            "load_fusefss_config ok for file [{s}]",
            .{config_file});
    var index: c_int = 0;
    while (c.toml_key_in(table, index)) |akey| : (index += 1)
    {
        const akey_slice = std.mem.sliceTo(akey, 0);
        if (std.mem.eql(u8, akey_slice, "main"))
        {
            const ltable = c.toml_table_in(table, akey);
            try err_if(ltable == null, TomlError.TomlTableInFailed);
            var lindex: c_int = 0;
            while (c.toml_key_in(ltable, lindex)) |alkey| : (lindex += 1)
            {
                const alkey_slice = std.mem.sliceTo(alkey, 0);
                _ = alkey_slice;
                _ = info;
            }
        }
    }
}
