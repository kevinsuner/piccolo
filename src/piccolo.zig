//
// Imports
//

const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const os = std.os;
const ascii = std.ascii;
const mem = std.mem;

//
// Data
//

const Editor = struct {
    screenrows: u16,
    screencols: u16,
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

fn clean(e: *Editor) !void {
    _ = os.write(os.linux.STDOUT_FILENO, "\x1b[2J") catch |err| {
        try disableRawMode(e);
        debug.print("write: {s}\n", .{@errorName(err)});
        os.exit(1);
    };

    _ = os.write(os.linux.STDOUT_FILENO, "\x1b[H") catch |err| {
        try disableRawMode(e);
        debug.print("write: {s}\n", .{@errorName(err)});
        os.exit(1);
    };

    try disableRawMode(e);
    os.exit(0);
}

fn die(e: *Editor, str: []const u8, err: anyerror, code: u8) !void {
    _ = os.write(os.linux.STDOUT_FILENO, "\x1b[2J") catch |werr| {
        try disableRawMode(e);
        debug.print("write: {s}\n", .{@errorName(werr)});
        os.exit(1);
    };

    _ = os.write(os.linux.STDOUT_FILENO, "\x1b[H") catch |werr| {
        try disableRawMode(e);
        debug.print("write: {s}\n", .{@errorName(werr)});
        os.exit(1);
    };

    try disableRawMode(e);

    debug.print("{s}: {s}\n", .{ str, @errorName(err) });
    os.exit(code);
}

fn disableRawMode(e: *Editor) !void {
    try os.tcsetattr(e.tty.handle, .FLUSH, e.og_termios);
}

fn enableRawMode(e: *Editor) !void {
    e.og_termios = try os.tcgetattr(e.tty.handle);
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

    try os.tcsetattr(e.tty.handle, .FLUSH, raw);
}

fn editorReadKey(tty: fs.File) !u8 {
    var buf: [1]u8 = undefined;
    _ = try tty.read(&buf);
    return buf[0];
}

fn getWindowSize(e: *Editor) i16 {
    var ws = mem.zeroes(os.linux.winsize);
    if (os.linux.ioctl(os.linux.STDOUT_FILENO, os.linux.T.IOCGWINSZ, @intFromPtr(&ws)) == -1 or
        ws.ws_col == 0)
    {
        return -1;
    } else {
        e.screenrows = ws.ws_row;
        e.screencols = ws.ws_col;
        return 0;
    }
}

//
// Output
//

fn editorDrawRows(e: *Editor) !void {
    var y: i8 = 0;
    while (y < e.screenrows) : (y += 1) {
        _ = try os.write(os.linux.STDOUT_FILENO, "~\r\n");
    }
}

fn editorRefreshScreen(e: *Editor) !void {
    _ = try os.write(os.linux.STDOUT_FILENO, "\x1b[2J");
    _ = try os.write(os.linux.STDOUT_FILENO, "\x1b[H");
    try editorDrawRows(e);
    _ = try os.write(os.linux.STDOUT_FILENO, "\x1b[H");
}

//
// Input
//

fn editorProcessKeypress(e: *Editor) !void {
    var c = try editorReadKey(e.tty);
    switch (c) {
        ctrlKey('q') => {
            try clean(e);
        },
        else => {},
    }
}

//
// Init
//

fn initEditor(e: *Editor) !void {
    if (getWindowSize(e) == -1) {
        try disableRawMode(e);
        debug.print("getWindowSize\n", .{});
        os.exit(1);
    }
}

pub fn main() !void {
    var tty = try fs.cwd().openFile("/dev/tty", .{ .mode = .read_write });
    defer tty.close();

    var e = Editor{ .screenrows = undefined, .screencols = undefined, .tty = tty, .og_termios = undefined };
    enableRawMode(&e) catch |err| {
        try die(&e, "enableRawMode", err, 1);
    };

    try initEditor(&e);

    while (true) {
        editorRefreshScreen(&e) catch |err| {
            try die(&e, "editorRefreshScreen", err, 1);
        };
        editorProcessKeypress(&e) catch |err| {
            try die(&e, "editorProcessKeypress", err, 1);
        };
    }
}
