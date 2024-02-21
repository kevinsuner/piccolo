// ==========================
// Imports
// ==========================

const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const os = std.os;
const ascii = std.ascii;
const mem = std.mem;
const linux = os.linux;
const fmt = std.fmt;
const heap = std.heap;

// ==========================
// Data
// ==========================

const Editor = struct {
    screencols: u16,
    screenrows: u16,
    tty: fs.File,
    og_termios: os.termios,
    allocator: mem.Allocator,
};

// ==========================
// Utilities
// ==========================

fn ctrlKey(k: u8) u8 {
    return (k) & 0x1f;
}

// ==========================
// Terminal
// ==========================

fn clean(e: *Editor) !void {
    _ = os.write(os.STDOUT_FILENO, "\x1b[2J") catch |err| {
        try disableRawMode(e);
        debug.print("os.write: {s}\n", .{@errorName(err)});
        os.exit(1);
    };

    _ = os.write(os.STDOUT_FILENO, "\x1b[H") catch |err| {
        try disableRawMode(e);
        debug.print("os.write: {s}\n", .{@errorName(err)});
        os.exit(1);
    };

    try disableRawMode(e);
    os.exit(0);
}

fn die(e: *Editor, str: []const u8, erro: anyerror, code: u8) !void {
    _ = os.write(os.STDOUT_FILENO, "\x1b[2J") catch |err| {
        try disableRawMode(e);
        debug.print("os.write: {s}\n", .{@errorName(err)});
        os.exit(1);
    };

    _ = os.write(os.STDOUT_FILENO, "\x1b[H") catch |err| {
        try disableRawMode(e);
        debug.print("os.write: {s}\n", .{@errorName(err)});
        os.exit(1);
    };

    try disableRawMode(e);

    debug.print("{s}: {s}\n", .{ str, @errorName(erro) });
    os.exit(code);
}

fn disableRawMode(e: *Editor) !void {
    try os.tcsetattr(e.tty.handle, .FLUSH, e.og_termios);
}

fn enableRawMode(e: *Editor) !void {
    e.og_termios = try os.tcgetattr(e.tty.handle);
    var raw = e.og_termios;
    
    raw.iflag &= ~@as(
        os.tcflag_t,
        linux.IXON | linux.ICRNL | linux.BRKINT | linux.INPCK | linux.ISTRIP,
    );
    raw.oflag &= ~@as(
        os.tcflag_t,
        linux.OPOST,
    );
    raw.cflag |= @as(
        os.tcflag_t,
        linux.CS8,
    );
    raw.lflag &= ~@as(
        os.tcflag_t,
        linux.ECHO | linux.ICANON | linux.ISIG | linux.IEXTEN,
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

fn getCursorPosition(e: *Editor) !i16 {
    var buf = std.ArrayList(u8).init(e.allocator);
    defer buf.deinit();

    var wsize = try os.write(os.STDOUT_FILENO, "\x1b[6n");
    if (wsize != 4) return -1;

    while (true) {
        var char: [1]u8 = undefined;
        var rsize = try os.read(os.STDOUT_FILENO, &char);
        if (rsize != 1) break;

        if (char[0] == '\x1b') continue;
        if (char[0] == 'R') break;
        try buf.append(char[0]);
    }

    var i: u8 = 0;
    var numbers: [2]u16 = undefined;
    var tokenizer = mem.tokenize(u8, buf.items, ";[");
    while (tokenizer.next()) |token| {
        const number = try fmt.parseInt(u16, token, 10);
        numbers[i] = number;
        i += 1;
    }

    e.screencols = numbers[0];
    e.screenrows = numbers[1];
    
    _ = try editorReadKey(e.tty);
    return 0;
}

fn getWindowSize(e: *Editor) !i16 {
    var ws = mem.zeroes(linux.winsize);
    if (linux.ioctl(os.STDOUT_FILENO, linux.T.IOCGWINSZ, @intFromPtr(&ws)) == -1 or ws.ws_col == 0) {
        var size = try os.write(os.STDOUT_FILENO, "\x1b[999C\x1b[999B");
        if (size != 12) return -1;
        return try getCursorPosition(e);
    } else {
        e.screencols = ws.ws_col;
        e.screenrows = ws.ws_row;
        return 0;
    }
}

// ==========================
// Output
// ==========================

fn editorDrawRows(e: *Editor) !void {
    var i: u8 = 0;
    while (i < e.screenrows) : (i += 1) {
        _ = try os.write(os.STDOUT_FILENO, "~");
        if (i < e.screenrows - 1) _ = try os.write(os.STDOUT_FILENO, "\r\n");
    }
}

fn editorRefreshScreen(e: *Editor) !void {
    _ = try os.write(os.STDOUT_FILENO, "\x1b[2J");
    _ = try os.write(os.STDOUT_FILENO, "\x1b[H");
    try editorDrawRows(e);
    _ = try os.write(os.STDOUT_FILENO, "\x1b[H");
}

// ==========================
// Input
// ==========================

fn editorProcessKeypress(e: *Editor) !void {
    var c = try editorReadKey(e.tty);
    switch (c) {
        ctrlKey('q') => {
            try clean(e);
        },
        else => {},
    }
}

// ==========================
// Init
// ==========================

fn initEditor(e: *Editor) !void {
    var ws = try getWindowSize(e);
    if (ws == -1) {
        try disableRawMode(e);
        debug.print("getWindowSize\n", .{});
        os.exit(1);
    }
}

pub fn main() !void {
    var gpa = heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) @panic("leak detected");
    }

    var tty = try fs.cwd().openFile("/dev/tty", .{ .mode = .read_write });
    defer tty.close();

    var e = Editor{
        .screenrows = undefined, 
        .screencols = undefined, 
        .tty = tty, 
        .og_termios = undefined,
        .allocator = allocator,
    };
    
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
