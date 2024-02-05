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

fn clean(e: *Editor) !void {
    _ = try os.write(os.linux.STDOUT_FILENO, "\x1b[2J");
    _ = try os.write(os.linux.STDOUT_FILENO, "\x1b[H");
    try disableRawMode(e);
    os.exit(0);
}

fn die(e: *Editor, str: []const u8, err: anyerror, code: u8) !void {
    _ = try os.write(os.linux.STDOUT_FILENO, "\x1b[2J");
    _ = try os.write(os.linux.STDOUT_FILENO, "\x1b[H");
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

//
// Output
//

fn editorDrawRows() !void {
    var y: i8 = 0;
    while (y < 24) : (y += 1) {
        _ = try os.write(os.linux.STDOUT_FILENO, "~\r\n");
    }
}

fn editorRefreshScreen() !void {
    _ = try os.write(os.linux.STDOUT_FILENO, "\x1b[2J");
    _ = try os.write(os.linux.STDOUT_FILENO, "\x1b[H");
    try editorDrawRows();
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

pub fn main() !void {
    var tty = try fs.cwd().openFile("/dev/tty", .{ .mode = .read_write });
    defer tty.close();

    var e = Editor{ .tty = tty, .og_termios = undefined };
    enableRawMode(&e) catch |err| {
        try die(&e, "enableRawMode", err, 1);
    };

    while (true) {
        editorRefreshScreen() catch |err| {
            try die(&e, "editorRefreshScreen", err, 1);
        };
        editorProcessKeypress(&e) catch |err| {
            try die(&e, "editorProcessKeypress", err, 1);
        };
    }
}
