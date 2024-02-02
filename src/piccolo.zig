// --- Imports ---

const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const os = std.os;
const ascii = std.ascii;

// --- Data ---

const Terminal = struct {
	tty: fs.File,
	og_termios: os.termios,
};

// --- Terminal ---

fn die(str: []const u8, err: anyerror) void {
	debug.print("{s}: {s}\n", .{str, @errorName(err)});
	os.exit(1);
}

fn disableRawMode(self: *Terminal) void {
	_ = os.tcsetattr(self.tty.handle, .FLUSH, self.og_termios) catch |err| {
		die("tcsetattr", err);
	};
}

fn enableRawMode(self: *Terminal) void {
	self.og_termios = os.tcgetattr(self.tty.handle) catch |err| {
		die("tcgetattr", err);
		return undefined;
	};

	var raw = self.og_termios;
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

	_ = os.tcsetattr(self.tty.handle, .FLUSH, raw) catch |err| { 
		die("tcsetattr", err); 
	};
}

// --- Init ---

pub fn main() void {
	var tty = fs.cwd().openFile("/dev/tty", .{ .mode = .read_write }) catch |err| {
		die("read", err);
		return undefined;
	};
	defer tty.close();

	var term = Terminal{ .tty = tty, .og_termios = undefined };
	enableRawMode(&term);
	defer disableRawMode(&term);

	while (true) {
		var buffer = [1]u8{'\u{0000}'};
		_ = term.tty.read(&buffer) catch |err| {
			die("read", err);
		};
		
		if (ascii.isControl(buffer[0])) {
			debug.print("{d}\r\n", .{buffer[0]});
		} else {
			debug.print("{d} ('{c}')\r\n", .{buffer[0], buffer[0]});
		}

		if (buffer[0] == 'q') break;
	}
}
