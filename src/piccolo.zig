const std = @import("std");
const debug = std.debug;
const fs = std.fs;
const os = std.os;

const Terminal = struct {
	tty: fs.File,
	og_termios: os.termios,
};

fn disableRawMode(self: *Terminal) void {
	_ = os.tcsetattr(self.tty.handle, .FLUSH, self.og_termios) catch |err| {
		debug.print("{}\n", .{err});
	};
}

fn enableRawMode(self: *Terminal) !void {
	self.og_termios = try os.tcgetattr(self.tty.handle);

	var raw = self.og_termios;
	raw.lflag &= ~@as(
		os.linux.tcflag_t,
		os.linux.ECHO,
	);

	try os.tcsetattr(self.tty.handle, .FLUSH, raw);
}

pub fn main() !void {
	var tty = try fs.cwd().openFile("/dev/tty", .{ .mode = .read_write });
	defer tty.close();

	var term = Terminal{ .tty = tty, .og_termios = undefined };
	try enableRawMode(&term);
	defer disableRawMode(&term);

	while (true) {
		var buffer: [1]u8 = undefined;
		_ = try term.tty.read(&buffer);
		if (buffer[0] == 'q') {
			return;
		} else {
			debug.print("input: {} {s}\r\n", .{ buffer[0], buffer });
		}
	}
}
