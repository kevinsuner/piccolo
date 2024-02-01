const std = @import("std");
const debug = std.debug;
const fs = std.fs;

pub fn main() !void {
	var tty = try fs.cwd().openFile("/dev/tty", .{ .mode = .read_write });
	defer tty.close();

	while (true) {
		var buffer: [1]u8 = undefined;
		_ = try tty.read(&buffer);
		if (buffer[0] == 'q') {
			return;
		} else {
			debug.print("input: {} {s}\r\n", .{ buffer[0], buffer });
		}
	}
}
