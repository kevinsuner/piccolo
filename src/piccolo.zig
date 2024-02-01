const std = @import("std");

pub fn main() !void {
	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	const allocator = gpa.allocator();
	defer _ = gpa.deinit();

	const in = std.io.getStdIn();
	var buf = std.io.bufferedReader(in.reader());
	var r = buf.reader();

	var input = std.ArrayList(u8).init(allocator);
	defer input.deinit();

	while (true) {
		const b = r.readByte() catch |err| switch (err) {
			error.EndOfStream => break,
			else => return err, 
		};

		if (b == 'q') {
			break;
		}
	}
	
	return;
}
