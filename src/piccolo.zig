const std = @import("std");
const ArrayList = std.ArrayList;
const mem = std.mem;
const fs = std.fs;
const os = std.os;
const heap = std.heap;
const process = std.process;
const linux = std.os.linux;
const system = std.os.system;
const fmt = std.fmt;
const io = std.io;

/// A representation of the keys used by the editor that does not conflict
/// with any ordinary keypresses.
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

/// A structure for storing the size and the characters in a editor row.
const EditorRow = struct {
    /// The size of the row.
    size: u32, // unsigned so no negative values are allowed
    /// The characters of the row.
    chars: []u8,
};

/// A structure for storing the configuration and state of the editor.
const Editor = struct {
    /// The position of the cursor relative to the X axis.
    cursor_x: u32,
    /// The position of the cursor relative to the Y axis.
    cursor_y: u32,
    /// The number of columns of the terminal.
    screen_cols: u32,
    /// The number of rows of the terminal.
    screen_rows: u32,
    /// The number of rows in-use by the editor.
    num_rows: u32,
    /// The row where the user is currenlty scrolled to.
    row_offset: u32,
    /// The rows stored by the editor.
    row: ArrayList(EditorRow),
    /// The buffer responsible of storing all the characters printed out at
    /// every screen refresh.
    write_buf: ArrayList(u8),
    /// The allocator responsible for allocating and freeing memory.
    allocator: mem.Allocator,
    /// The file that represents the terminal for the current process.
    tty: fs.File,
    /// The system's terminal settings.
    termios: os.termios,
    
    /// Initializes access to /dev/tty for controlling the terminal, processes
    /// the provided command-line arguments if any, puts the terminal in raw or
    /// `uncooked` mode, and opens the file passed through command-line arguments.
    fn init(self: *Editor) !void {
        self.tty = try fs.cwd().openFile("/dev/tty", .{ .mode = .read_write });
        self.row = ArrayList(EditorRow).init(self.allocator);

        var args = try process.argsAlloc(self.allocator);
        defer process.argsFree(self.allocator, args);
        
        try self.enableRawMode();
        if (try self.getWindowSize() == -1) {
            std.debug.print("getWindowSize\n", .{});
            os.exit(1);
        }
        
        try self.openFile(args[1]);
        
        std.debug.print("I have been inited: {d}\n", .{self.cursor_x});
    }

    /// Turns off the necessary flags to put the terminal in raw or `uncooked` mode,
    /// making reading keypresses from the user possible.
    ///
    /// The `lflag` field is for `local flags` or `miscellaneous flags`. The other
    /// flag fields are `iflag` which refers to `input flags`, `oflag` which refers
    /// to `output flags`, and `cflag` which refers to `control flags`.
    ///
    /// `ECHO` is a bitflag defined as 00000000000000000000000000001000 in binary.
    /// We use the bitwise-NOT operator `~` on this value to get on this value to
    /// get 11111111111111111111111111110111. We then bitwise-AND this value with
    /// the flags field, which forces the fourth bit in the flags field to become
    /// `0`, and causes every other bit to retain its current value. 
    ///
    /// `ICANON` allows us to turn off canonical mode, generally input flags, the
    /// ones in the `iflag` field start with `I` like `ICANON` does. However `ICANON`
    /// is not an input flag, it's a local flag in the `lflag` field.
    ///
    /// `ISIG` disables `CTRL-C` which produces a `SIGINT` signal, `CTRL-Z` which
    /// produces a `SIGTSTP` signal and also disables `CTRL-Y` on macOS.
    ///
    /// `IXON` disables `CTRL-S` which produces a `XOFF` signal and `CTRL-Q` which
    /// produces a `XON` signal.
    ///
    /// `IEXTEN` disables `CTRL-V` and also disables `CTRL-O` on macOS.
    /// `ICRNL` makes `CTRL-M` to be read as a carriage return.
    /// `OPOST` turns off all output processing features.
    /// `BRKINT` disables `CTRL-C` from causing a `SIGINT` signal.
    /// `INPCK` enables parity checking.
    /// `ISTRIP` causes the 8th bit of each input byte to be set to `0`.
    ///
    /// `CS8` is not a flag, it is a bit mask with multiple bits, which we set using
    /// the bitwise-OR `|` operator unlike the other flags. It sets the character
    /// size `CS` to 8 bits per byte.
    ///
    /// `V.MIN` sets the minimum number of bytes of input needed before `read()` can
    /// return.
    ///
    /// `V.TIME` sets the maximum amount of time to wait before `read()` returns.
    /// Its in tenths of a second, 1/10 of a second, or 100 milliseconds.  
    fn enableRawMode(self: *Editor) !void {
        self.termios = try os.tcgetattr(self.tty.handle);
        var raw = self.termios;

        raw.iflag &= ~@as(
            os.tcflag_t,
            linux.IXON | linux.ICRNL | linux.BRKINT | linux.INPCK | linux.ISTRIP,
        );

        raw.oflag &= ~@as(os.tcflag_t, linux.OPOST);
        raw.cflag |= @as(os.tcflag_t, linux.CS8);

        raw.lflag &= ~@as(
            os.tcflag_t,
            linux.ECHO | linux.ICANON | linux.ISIG | linux.IEXTEN,
        );

        raw.cc[system.V.MIN] = 0;
        raw.cc[system.V.TIME] = 1;

        try os.tcsetattr(self.tty.handle, .FLUSH, raw);
    }

    /// It uses `ioctl()` to determine the number of rows and columns, and
    /// `getCursorPosition` as a fallback to get the number of rows and columns.
    fn getWindowSize(self: *Editor) !i8 {
        var ws = mem.zeroes(linux.winsize);
        if (linux.ioctl(os.STDOUT_FILENO, linux.T.IOCGWINSZ, @intFromPtr(&ws)) == -1 or 
            ws.ws_col == 0) {
            if (try os.write(os.STDOUT_FILENO, "\x1b[999C\x1b[999B") != 12) return -1;
            return try self.getCursorPosition();
        } else {
            self.screen_cols = ws.ws_col;
            self.screen_rows = ws.ws_row;
            return 0;
        }
    }

    /// Determines the number of rows and columns, by positioning the cursor at
    /// the bottom-right of the screen and using escape sequences, to query the
    /// position of the cursor.
    fn getCursorPosition(self: *Editor) !i8 {
        var buf = ArrayList(u8).init(self.allocator);
        defer buf.deinit();

        if (try os.write(os.STDOUT_FILENO, "\x1b[6n") != 4) return -1;

        while (true) {
            var char: [1]u8 = undefined;
            if (try os.read(os.STDOUT_FILENO, &char) != 1) break;

            if (char[0] == '\x1b') continue;
            if (char[0] == 'R') break;
            try buf.append(char[0]);
        }

        var i: u16 = 0;
        var numbers: [2]u16 = undefined;
        var tokenizer = mem.tokenize(u8, buf.items, ";[");
        while (tokenizer.next()) |token| : (i += 1) {
            numbers[i] = try fmt.parseInt(u16, token, 10);
        }

        self.screen_cols = numbers[0];
        self.screen_rows = numbers[1];

        _ = try self.editorReadKey();
        return 0;
    }

    /// Determines whether a keypress is an escape sequence, and in that case
    /// processes it and gives it a representation, or if it just a regular keypress.
    fn editorReadKey(self: *Editor) !u32 {
        var buf: [1]u8 = undefined;
        _ = try self.tty.read(&buf);

        if (buf[0] == '\x1b') {
            var first_seq: [1]u8 = undefined;
            var second_seq: [1]u8 = undefined;
            if (try os.read(os.STDOUT_FILENO, &first_seq) != 1 or
                try os.read(os.STDOUT_FILENO, &second_seq) != 1) return '\x1b';

            if (first_seq[0] == '[') {
                if (first_seq[0] >= '0' and first_seq[0] <= '9') {
                    var third_seq: [1]u8 = undefined;
                    if (try os.read(os.STDOUT_FILENO, &third_seq) != 1) return '\x1b';

                    if (third_seq[0] == '~') {
                        switch (second_seq[0]) {
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
                    switch (second_seq[0]) {
                        'A' => return @intFromEnum(EditorKey.arrow_up),
                        'B' => return @intFromEnum(EditorKey.arrow_down),
                        'C' => return @intFromEnum(EditorKey.arrow_right),
                        'D' => return @intFromEnum(EditorKey.arrow_left),
                        'H' => return @intFromEnum(EditorKey.home_key),
                        'F' => return @intFromEnum(EditorKey.end_key),
                        else => {},
                    }
                }
            } else if (first_seq[0] == 'O') {
                switch (second_seq[0]) {
                    'H' => return @intFromEnum(EditorKey.home_key),
                    'F' => return @intFromEnum(EditorKey.end_key),
                    else => {},
                }
            }

            return '\x1b';
        } else {
            return @as(u32, buf[0]);
        }
    }

    /// Uses the path from the arguments to open a file for reading and writing,
    /// streams each line until a delimiter is found, and appends it to a new editor row.
    fn openFile(self: *Editor, path: []const u8) !void {
        var file = try fs.cwd().openFile(path, .{ .mode = .read_write });
        defer file.close();

        var buf_reader = io.bufferedReader(file.reader());
        const reader = buf_reader.reader();

        var line = std.ArrayList(u8).init(self.allocator);
        defer line.deinit();

        const writer = line.writer();
        while (reader.streamUntilDelimiter(writer, '\n', null)) {
            defer line.clearRetainingCapacity();
            try self.editorAppendRow(line.items);
        } else |err| switch (err) {
            error.EndOfStream => {},
            else => return err,
        }
    }

    /// Allocates a new null-terminated string using the items passed through the
    /// arguments, and appends a new row to the editor.
    fn editorAppendRow(self: *Editor, items: []u8) !void {
        var str = try fmt.allocPrint(self.allocator, "{s}\u{0000}", .{items});
        defer self.allocator.free(str);

        try self.row.append(.{ .size = @intCast(str.len), .chars = str });
        self.num_rows += 1;
    }
};

pub fn main() !void {
    var editor = Editor{
        .cursor_x = 0,
        .cursor_y = 0,
        .screen_cols = 0,
        .screen_rows = 0,
        .num_rows = 0,
        .row_offset = 0,
        .row = undefined,
        .write_buf = undefined,
        .allocator = undefined,
        .tty = undefined,
        .termios = undefined,
    };

    var gpa = heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) @panic("leak detected");
    }
    
    editor.allocator = gpa.allocator();
    
    try editor.init();
    defer editor.tty.close();
    defer editor.row.deinit();
}
