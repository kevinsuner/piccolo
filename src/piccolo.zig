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
// Terminal
//

fn die(str: []const u8, err: anyerror) void {
    debug.print("{s}: {s}\n", .{ str, @errorName(err) });
    os.exit(1);
}

fn disableRawMode(e: *Editor) void {
    os.tcsetattr(e.tty.handle, .FLUSH, e.og_termios) catch |err| {
        die("tcsetattr", err);
    };
}

fn enableRawMode(e: *Editor) void {
    e.og_termios = os.tcgetattr(e.tty.handle) catch |err| {
        die("tcgetattr", err);
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
        die("tcsetattr", err);
    };
}

//
// Init
//

pub fn main() void {
    var tty = fs.cwd().openFile("/dev/tty", .{ .mode = .read_write }) catch |err| {
        die("openFile", err);
        return undefined;
    };
    defer tty.close();

    var e = Editor{ .tty = tty, .og_termios = undefined };
    enableRawMode(&e);
    defer disableRawMode(&e);

    while (true) {
        var buf = [1]u8{'\u{0000}'};
        _ = e.tty.read(&buf) catch |err| {
            die("read", err);
        };

        if (ascii.isControl(buf[0])) {
            debug.print("{d}\r\n", .{buf[0]});
        } else {
            debug.print("{d} ('{c}')\r\n", .{ buf[0], buf[0] });
        }

        if (buf[0] == 'q') break;
    }
}
