const std = @import("std");
const builtin = @import("builtin");

//*****************************************************************************
pub fn build(b: *std.Build) !void
{
    // build options
    const do_strip = b.option(
        bool,
        "strip",
        "Strip the executabes"
    ) orelse false;
    try update_git_zig(b.allocator);
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // fusefss
    const fusefss = myAddExecutable(b, "fusefss", target,optimize, do_strip);
    fusefss.root_module.root_source_file = b.path("src/fusefss.zig");
    fusefss.linkLibC();
    fusefss.addIncludePath(b.path("src"));
    fusefss.addCSourceFiles(.{.files = libtomlc_files});
    fusefss.root_module.addImport("hexdump", b.createModule(.{
        .root_source_file = b.path("common/hexdump.zig"),
    }));
    fusefss.root_module.addImport("log", b.createModule(.{
        .root_source_file = b.path("common/log.zig"),
    }));
    fusefss.root_module.addImport("parse", b.createModule(.{
        .root_source_file = b.path("common/parse.zig"),
    }));
    setExtraLibraryPaths(fusefss, target);
    b.installArtifact(fusefss);
    // fusefsc
    const fusefsc = myAddExecutable(b, "fusefsc", target,optimize, do_strip);
    fusefsc.root_module.root_source_file = b.path("src/fusefsc.zig");
    fusefsc.linkLibC();
    fusefsc.addIncludePath(b.path("src"));
    fusefsc.addCSourceFiles(.{.files = libtomlc_files});
    fusefsc.root_module.addImport("hexdump", b.createModule(.{
        .root_source_file = b.path("common/hexdump.zig"),
    }));
    fusefsc.root_module.addImport("log", b.createModule(.{
        .root_source_file = b.path("common/log.zig"),
    }));
    fusefsc.root_module.addImport("parse", b.createModule(.{
        .root_source_file = b.path("common/parse.zig"),
    }));
    setExtraLibraryPaths(fusefsc, target);
    b.installArtifact(fusefsc);
}

//*****************************************************************************
fn setExtraLibraryPaths(compile: *std.Build.Step.Compile,
        target: std.Build.ResolvedTarget) void
{
    if (target.result.cpu.arch == std.Target.Cpu.Arch.x86)
    {
        // zig seems to use /usr/lib/x86-linux-gnu instead
        // of /usr/lib/i386-linux-gnu
        compile.addLibraryPath(.{.cwd_relative = "/usr/lib/i386-linux-gnu/"});
    }
}

//*****************************************************************************
fn myAddExecutable(b: *std.Build, name: []const u8,
        target: std.Build.ResolvedTarget,
        optimize: std.builtin.OptimizeMode,
        do_strip: bool) *std.Build.Step.Compile
{
    if ((builtin.zig_version.major == 0) and (builtin.zig_version.minor < 15))
    {
        return b.addExecutable(.{
            .name = name,
            .target = target,
            .optimize = optimize,
            .strip = do_strip,
        });
    }
    return b.addExecutable(.{
        .name = name,
        .root_module = b.addModule(name, .{
            .target = target,
            .optimize = optimize,
            .strip = do_strip,
        }),
    });
}

//*****************************************************************************
fn update_git_zig(allocator: std.mem.Allocator) !void
{
    const cmdline = [_][]const u8{"git", "describe", "--always"};
    const rv = try std.process.Child.run(
            .{.allocator = allocator, .argv = &cmdline});
    defer allocator.free(rv.stdout);
    defer allocator.free(rv.stderr);
    const file = try std.fs.cwd().createFile("src/git.zig", .{});

    if ((builtin.zig_version.major == 0) and
        (builtin.zig_version.minor < 15))
    {
        const writer = file.writer();
        var sha1 = rv.stdout;
        while ((sha1.len > 0) and (sha1[sha1.len - 1] < 0x20))
        {
            sha1.len -= 1;
        }
        try writer.print("pub const g_git_sha1 = \"{s}\";\n", .{sha1});
    }
    else
    {
        var buf: [1024]u8 = undefined;
        var file_writer = file.writer(&buf);
        const writer = &file_writer.interface;
        var sha1 = rv.stdout;
        while ((sha1.len > 0) and (sha1[sha1.len - 1] < 0x20))
        {
            sha1.len -= 1;
        }
        try writer.print("pub const g_git_sha1 = \"{s}\";\n", .{sha1});
        try writer.flush();
    }
}

const libtomlc_files = &.{
    "src/toml.c",
};
