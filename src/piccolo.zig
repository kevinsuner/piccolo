//
// Imports
//

const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const os = std.os;
const ascii = std.ascii;

//
// Data
//

const Editor = struct {
    tty: fs.File,
    og_termios: os.termios,
};

//
// Utilities
//

fn ctrlKey(k: u8) u8 {
    return (k) & 0x1f;
}

//
// Terminal
//

fn clean(e: *Editor) void {
    disableRawMode(e);
    os.exit(0);
}

fn die(e: *Editor, str: []const u8, err: anyerror, code: u8) void {
    disableRawMode(e);
    debug.print("{s}: {s}\n", .{ str, @errorName(err) });
    os.exit(code);
}

fn disableRawMode(e: *Editor) void {
    os.tcsetattr(e.tty.handle, .FLUSH, e.og_termios) catch |err| {
        debug.print("tcsetattr: {s}\n", .{@errorName(err)});
        os.exit(1);
    };
}

fn enableRawMode(e: *Editor) void {
    e.og_termios = os.tcgetattr(e.tty.handle) catch |err| {
        die(e, "tcgetattr", err, 1);
        return undefined;
    };

    var raw = e.og_termios;
    raw.iflag &= ~@as(
        os.linux.tcflag_t,
        os.linux.IXON | os.linux.ICRNL | os.linux.BRKINT | os.linux.INPCK | os.linux.ISTRIP,
    );
    raw.oflag &= ~@as(
        os.linux.tcflag_t,
        os.linux.OPOST,
    );
    raw.cflag |= @as(
        os.linux.tcflag_t,
        os.linux.CS8,
    );
    raw.lflag &= ~@as(
        os.linux.tcflag_t,
        os.linux.ECHO | os.linux.ICANON | os.linux.ISIG | os.linux.IEXTEN,
    );
    raw.cc[os.system.V.MIN] = 0;
    raw.cc[os.system.V.TIME] = 1;

    os.tcsetattr(e.tty.handle, .FLUSH, raw) catch |err| {
        die(e, "tcsetattr", err, 1);
    };
}

fn editorReadKey(e: *Editor) u8 {
    var buf: [1]u8 = undefined;
    _ = e.tty.read(&buf) catch |err| {
        die(e, "read", err, 1);
        return undefined;
    };

    return buf[0];
}

//
// Input
//

fn editorProcessKeypress(e: *Editor) void {
    var c = editorReadKey(e);
    switch (c) {
        ctrlKey('q') => {
            clean(e);
        },
        else => {},
    }
}

//
// Init
//

pub fn main() void {
    var tty = fs.cwd().openFile("/dev/tty", .{ .mode = .read_write }) catch |err| {
        debug.print("openFile: {s}\n", .{@errorName(err)});
        os.exit(1);
        return undefined;
    };
    defer tty.close();

    var e = Editor{ .tty = tty, .og_termios = undefined };
    enableRawMode(&e);

    while (true) {
        editorProcessKeypress(&e);
    }
}
