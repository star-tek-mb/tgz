const c = @cImport(@cInclude("signal.h"));
const std = @import("std");
const botlib = @import("bot.zig");
const Bot = botlib.Bot;
const File = botlib.File;

const photo = @embedFile("photo.jpg");
var running = true;

fn sig_handler(_: c_int) callconv(.C) void {
    running = false;
}

pub fn main() !void {
    _ = c.signal(c.SIGINT, sig_handler);
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    var allocator = gpa.allocator();
    var out = std.io.getStdOut().writer();

    try Bot.init();
    defer Bot.deinit();
    var bot = try Bot.create("", allocator);
    defer bot.destroy();

    try out.print("polling started\n", .{});
    while (running) {
        var upd = try bot.poll();
        if (upd) |*update| {
            defer update.deinit();

            var chat_id = try update.dot(i64, "message.chat.id");
            var text = try update.dot([]const u8, "message.text");

            try bot.do("sendPhoto", .{
                .chat_id = chat_id,
                .caption = text,
                .photo = File{photo},
            });
        }
    }
    try out.print("polling finished\n", .{});
}
