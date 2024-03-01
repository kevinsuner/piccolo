// ========================================================
// Imports
// ========================================================

const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const os = std.os;
const ascii = std.ascii;
const mem = std.mem;
const linux = os.linux;
const fmt = std.fmt;
const heap = std.heap;
const io = std.io;
const process = std.process;

// ========================================================
// Data
// ========================================================

const PICCOLO_VERSION = "0.1";

const EditorRow = struct {
    size: usize,
    chars: []u8,
};

const Editor = struct {
    cursor_x: u16,
    cursor_y: u16,
    row_offset: u16,
    screencols: u16,
    screenrows: u16,
    num_rows: u16,
    row: std.ArrayList(EditorRow),
    tty: fs.File,
    og_termios: os.termios,
    allocator: mem.Allocator,
    write_buf: std.ArrayList(u8),
};

const EditorKey = enum(u16) {
    arrow_left = 1000,
    arrow_right,
    arrow_up,
    arrow_down,
    del_key,
    home_key,
    end_key,
    page_up,
    page_down,
};

// ========================================================
// Utilities
// ========================================================

fn ctrlKey(k: u8) u8 {
    return (k) & 0x1f;
}

// ========================================================
// Terminal
// ========================================================

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

fn editorReadKey(tty: fs.File) !u16 {
    var buf: [1]u8 = undefined;
    _ = try tty.read(&buf);

    if (buf[0] == '\x1b') {
        var seq0: [1]u8 = undefined;
        var seq1: [1]u8 = undefined;
        var seq0_size = try os.read(os.STDOUT_FILENO, &seq0);
        var seq1_size = try os.read(os.STDOUT_FILENO, &seq1);
        if (seq0_size != 1 or seq1_size != 1) return '\x1b';

        if (seq0[0] == '[') {
            if (seq1[0] >= '0' and seq1[0] <= '9') {
                var seq2: [1]u8 = undefined; 
                var seq2_size = try os.read(os.STDOUT_FILENO, &seq2);
                if (seq2_size != 1) return '\x1b';

                if (seq2[0] == '~') {
                    switch (seq1[0]) {
                        '1' => return @intFromEnum(EditorKey.home_key),
                        '3' => return @intFromEnum(EditorKey.del_key),
                        '4' => return @intFromEnum(EditorKey.end_key),
                        '5' => return @intFromEnum(EditorKey.page_up),
                        '6' => return @intFromEnum(EditorKey.page_down),
                        '7' => return @intFromEnum(EditorKey.home_key),
                        '8' => return @intFromEnum(EditorKey.end_key),
                        else => {},
                    }
                }
            } else {
                switch (seq1[0]) {
                    'A' => return @intFromEnum(EditorKey.arrow_up),
                    'B' => return @intFromEnum(EditorKey.arrow_down),
                    'C' => return @intFromEnum(EditorKey.arrow_right),
                    'D' => return @intFromEnum(EditorKey.arrow_left),
                    'H' => return @intFromEnum(EditorKey.home_key),
                    'F' => return @intFromEnum(EditorKey.end_key),
                    else => {},
                }
            }
        } else if (seq0[0] == 'O') {
            switch (seq1[0]) {
                'H' => return @intFromEnum(EditorKey.home_key),
                'F' => return @intFromEnum(EditorKey.end_key),
                else => {},
            }
        }

        return '\x1b';
    } else {
        return @as(u16, buf[0]);
    }
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

// ========================================================
// Row Operations
// ========================================================

fn editorAppendRow(e: *Editor, items: []u8) !void {
    var str = try fmt.allocPrint(e.allocator, "{s}\u{0000}", .{items});
    try e.row.append(.{ .size = str.len, .chars = str });
    e.num_rows += 1;
}

// ========================================================
// File I/O
// ========================================================

fn editorOpen(e: *Editor, path: []const u8) !void {
    var file = try fs.cwd().openFile(path, .{ .mode = .read_write });
    defer file.close();

    var buf_reader = io.bufferedReader(file.reader());
    const reader = buf_reader.reader();

    var line = std.ArrayList(u8).init(e.allocator);
    defer line.deinit();

    const writer = line.writer();
    while (reader.streamUntilDelimiter(writer, '\n', null)) {
        defer line.clearRetainingCapacity();
        try editorAppendRow(e, line.items);
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return err,
    }
}

// ========================================================
// Output
// ========================================================

fn editorScroll(e: *Editor) void {
    if (e.cursor_y < e.row_offset) {
        e.row_offset = e.cursor_y;
    }

    if (e.cursor_y >= e.row_offset + e.screenrows) {
        e.row_offset = e.cursor_y - e.screenrows + 1;
    }
}

fn editorDrawRows(e: *Editor) !void {
    var y: u8 = 0;
    while (y < e.screenrows) : (y += 1) {
        var file_row = y + e.row_offset;
        if (file_row >= e.num_rows) {
            if (e.num_rows == 0 and y == e.screenrows / 3) {
                var welcome_msg = try fmt.allocPrint(e.allocator, "Piccolo Editor -- Version {s}", .{PICCOLO_VERSION});
                var padding: u64 = (e.screencols - welcome_msg.len) / 2;
                if (padding > 0) {
                    _ = try e.write_buf.writer().write("~");
                    padding -= 1;
                }

                while (padding > 0) : (padding -= 1) _ = try e.write_buf.writer().write(" ");
                _ = try e.write_buf.writer().write(welcome_msg);
            } else {
                _ = try e.write_buf.writer().write("~");
            }
        } else {
            var len = e.row.items[file_row].size;
            if (len > e.screencols) len = e.screencols;
            _ = try e.write_buf.writer().write(e.row.items[file_row].chars);
        }

        _ = try e.write_buf.writer().write("\x1b[K");
        if (y < e.screenrows - 1) _ = try e.write_buf.writer().write("\r\n");
    }
}

fn editorRefreshScreen(e: *Editor) !void {
    editorScroll(e);

    e.write_buf = std.ArrayList(u8).init(e.allocator);
    defer e.write_buf.deinit();

    _ = try e.write_buf.writer().write("\x1b[?25l");
    _ = try e.write_buf.writer().write("\x1b[H");
    
    try editorDrawRows(e);

    var buf = try fmt.allocPrint(e.allocator, "\x1b[{d};{d}H", .{(e.cursor_y - e.row_offset) + 1, e.cursor_x + 1});
    _ = try e.write_buf.writer().write(buf);
    
    _ = try e.write_buf.writer().write("\x1b[?25h");
    _ = try os.write(os.STDOUT_FILENO, e.write_buf.items);
}

// ========================================================
// Input
// ========================================================

fn editorMoveCursor(key: u16, e: *Editor) void {
    switch (key) {
        @intFromEnum(EditorKey.arrow_left) => {
            if (e.cursor_x != 0) e.cursor_x -= 1;
        },
        @intFromEnum(EditorKey.arrow_right) => {
            if (e.cursor_x != e.screencols - 1) e.cursor_x += 1;
        },
        @intFromEnum(EditorKey.arrow_up) => {
            if (e.cursor_y != 0) e.cursor_y -= 1;
        },
        @intFromEnum(EditorKey.arrow_down) => {
            if (e.cursor_y < e.num_rows) e.cursor_y += 1;
        },
        else => {},
    }
}

fn editorProcessKeypress(e: *Editor) !void {
    var c = try editorReadKey(e.tty);
    switch (c) {
        ctrlKey('q') => try clean(e),

        @intFromEnum(EditorKey.home_key) => e.cursor_x = 0,
        @intFromEnum(EditorKey.end_key) => e.cursor_x = e.screencols - 1,

        @intFromEnum(EditorKey.page_up),
        @intFromEnum(EditorKey.page_down) => {
            var times = e.screenrows;
            while (times > 0) : (times -= 1) {
                if (c == @intFromEnum(EditorKey.page_up)) {
                    editorMoveCursor(@intFromEnum(EditorKey.arrow_up), e);
                } else {
                    editorMoveCursor(@intFromEnum(EditorKey.arrow_down), e);
                }
            }
        },
        
        @intFromEnum(EditorKey.arrow_left),
        @intFromEnum(EditorKey.arrow_right),
        @intFromEnum(EditorKey.arrow_up),
        @intFromEnum(EditorKey.arrow_down) => editorMoveCursor(c, e),
        else => {},
    }
}

// ========================================================
// Init
// ========================================================

fn initEditor(e: *Editor) !void {
    e.cursor_x = 0;
    e.cursor_y = 0;
    e.row_offset = 0;
    e.num_rows = 0;

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

    var args = try process.argsAlloc(allocator);
    defer process.argsFree(allocator, args);

    var row = std.ArrayList(EditorRow).init(allocator);
    defer row.deinit();

    var e = Editor{
        .cursor_x = undefined,
        .cursor_y = undefined,
        .row_offset = undefined,
        .screencols = undefined, 
        .screenrows = undefined,
        .num_rows = undefined,
        .row = row,
        .tty = tty, 
        .og_termios = undefined,
        .allocator = allocator,
        .write_buf = undefined,
    };
    
    enableRawMode(&e) catch |err| try die(&e, "enableRawMode", err, 1);
    try initEditor(&e);
    try editorOpen(&e, args[1]);

    while (true) {
        editorRefreshScreen(&e) catch |err| try die(&e, "editorRefreshScreen", err, 1);
        editorProcessKeypress(&e) catch |err| try die(&e, "editorProcessKeypress", err, 1);
    }
}
