const std = @import("std");
const c = @cImport({
    @cDefine("JSMN_HEADER", {});
    @cInclude("jsmn.h");
    @cInclude("curl/curl.h");
});

pub const File = struct { []const u8 };

pub const Response = struct {
    allocator: std.mem.Allocator,
    json: []const u8,
    tokens: []c.jsmntok_t,

    pub fn parse(allocator: std.mem.Allocator, data: []const u8) !Response {
        var json = try allocator.dupe(u8, data);

        var parser: c.jsmn_parser = undefined;
        c.jsmn_init(&parser);
        var tokens_count = c.jsmn_parse(&parser, json.ptr, json.len, null, 0);
        if (tokens_count < 0) {
            return error.BotBadResponse;
        }
        var tokens = try allocator.alloc(c.jsmntok_t, @as(usize, @intCast(tokens_count)));
        c.jsmn_init(&parser);
        _ = c.jsmn_parse(&parser, json.ptr, json.len, tokens.ptr, @as(c_uint, @intCast(tokens.len)));

        return .{
            .allocator = allocator,
            .json = json,
            .tokens = tokens,
        };
    }

    pub fn dot(self: *Response, comptime OriginalT: type, field: []const u8) !OriginalT {
        var tok = self.dot_token(field);
        if (tok) |token| {
            const T = blk: {
                if (@typeInfo(OriginalT) == .Optional) {
                    break :blk @typeInfo(OriginalT).Optional.child;
                } else {
                    break :blk OriginalT;
                }
            };
            var value = self.json[@as(usize, @intCast(token.start))..@as(usize, @intCast(token.end))];
            if ((token.type == c.JSMN_STRING or token.type == c.JSMN_PRIMITIVE) and T == []const u8) {
                // return string
                return value;
            } else if (token.type == c.JSMN_PRIMITIVE) {
                // return null
                if (value[0] == 'n') {
                    if (@typeInfo(OriginalT) == .Optional) {
                        return null;
                    } else {
                        return error.TypeOptionalExpected;
                    }
                }
                // return boolean
                if (T == bool) {
                    if (value[0] == 't') {
                        return true;
                    } else if (value[0] == 'f') {
                        return false;
                    } else {
                        return error.TypeMismatch;
                    }
                }
                // return number
                return switch (@typeInfo(T)) {
                    .Int, .ComptimeInt => try std.fmt.parseInt(T, value, 10),
                    .Float, .ComptimeFloat => try std.fmt.parseFloat(T, value),
                    else => error.TypeMismatch,
                };
            } else if (token.type == c.JSMN_OBJECT or token.type == c.JSMN_ARRAY) {
                // return array or object length
                return switch (@typeInfo(T)) {
                    .Int, .ComptimeInt => @as(T, @intCast(token.size)),
                    else => error.TypeMismatch,
                };
            } else {
                // nothing is matched
                return error.TypeMismatch;
            }
        }
        return error.KeyNotFound;
    }

    pub fn dot_token(self: *Response, field: []const u8) ?c.jsmntok_t {
        var current_token: usize = 0;
        var depth: usize = 0;
        var search_depth: usize = 0;
        var iter = std.mem.split(u8, field, ".");
        while (iter.next()) |current| {
            search_depth += 1;
            var found = false;
            while (current_token < self.tokens.len) {
                var tok = self.tokens[current_token];
                if (tok.type == c.JSMN_OBJECT) {
                    depth += 1;
                    current_token += 1;
                    const object_length = @as(usize, @intCast(tok.size));
                    for (0..@as(usize, @intCast(object_length))) |_| {
                        var key_tok = self.tokens[current_token];
                        var key = self.json[@as(usize, @intCast(key_tok.start))..@as(usize, @intCast(key_tok.end))];
                        current_token += 1;
                        if (std.mem.eql(u8, key, current)) {
                            found = true;
                            break;
                        }
                        skipToken(self.tokens, &current_token);
                    }
                    if (found) break;
                    depth -= 1;
                } else if (tok.type == c.JSMN_ARRAY) {
                    depth += 1;
                    const array_length = @as(usize, @intCast(tok.size));

                    if (depth == search_depth and (std.ascii.isDigit(current[0]) or current[0] == '-')) {
                        found = true;
                        var index = std.fmt.parseInt(i64, current, 10) catch unreachable;
                        if (index < 0) {
                            index = @as(i64, @intCast(array_length)) - (std.math.absInt(index) catch unreachable);
                        }
                        if (index < 0 or index >= array_length) unreachable;

                        current_token += 1;
                        for (0..@as(usize, @intCast(index))) |_| {
                            skipToken(self.tokens, &current_token);
                        }
                        break;
                    }
                    skipToken(self.tokens, &current_token);
                    depth -= 1;
                } else {
                    return null;
                }
            }
            if (!found) return null;
        }
        return self.tokens[current_token];
    }

    pub fn deinit(self: *Response) void {
        self.allocator.free(self.tokens);
        self.allocator.free(self.json);
    }
};

pub const Update = Response;

pub const Bot = struct {
    token: []const u8,
    allocator: std.mem.Allocator,
    curl: *c.CURL,
    data: std.ArrayListUnmanaged(u8),
    last_update: usize,

    pub fn init() !void {
        if (c.curl_global_init(c.CURL_GLOBAL_DEFAULT) != 0) return error.BotInitializationError;
    }

    pub fn create(token: []const u8, allocator: std.mem.Allocator) !Bot {
        var curl = c.curl_easy_init();
        if (curl == null) return error.BotCreationError;
        _ = c.curl_easy_setopt(curl, c.CURLOPT_SSL_VERIFYPEER, @as(c_int, 0));
        _ = c.curl_easy_setopt(curl, c.CURLOPT_SSL_VERIFYHOST, @as(c_int, 0));
        return .{
            .token = token,
            .allocator = allocator,
            .curl = curl.?,
            .data = .{},
            .last_update = 0,
        };
    }

    pub fn destroy(self: *Bot) void {
        self.data.clearAndFree(self.allocator);
        c.curl_easy_cleanup(self.curl);
    }

    fn request(self: *Bot, name: []const u8, params: anytype, data: bool) !void {
        if (data) {
            self.data.clearRetainingCapacity();
        }

        var url_buffer: [512]u8 = undefined;
        var url = try std.fmt.bufPrintZ(&url_buffer, "https://api.telegram.org/bot{s}/{s}", .{ self.token, name });
        _ = c.curl_easy_setopt(self.curl, c.CURLOPT_URL, url.ptr);
        _ = c.curl_easy_setopt(self.curl, c.CURLOPT_CONNECTTIMEOUT, @as(c_int, 3));
        _ = c.curl_easy_setopt(self.curl, c.CURLOPT_TIMEOUT, @as(c_int, 20));
        if (data) {
            _ = c.curl_easy_setopt(self.curl, c.CURLOPT_WRITEFUNCTION, memory_writer);
        } else {
            _ = c.curl_easy_setopt(self.curl, c.CURLOPT_WRITEFUNCTION, null_writer);
        }
        _ = c.curl_easy_setopt(self.curl, c.CURLOPT_WRITEDATA, @as(*Bot, self));

        var form = c.curl_mime_init(self.curl);
        defer c.curl_mime_free(form);

        const params_type = @TypeOf(params);
        if (@typeInfo(params_type).Struct.fields.len > 0) {
            var field: ?*c.curl_mimepart = null;
            inline for (@typeInfo(params_type).Struct.fields) |struct_field| {
                field = c.curl_mime_addpart(form);
                var buffer: [struct_field.name.len + 1]u8 = undefined;
                var field_name = try std.fmt.bufPrintZ(&buffer, "{s}", .{struct_field.name});
                _ = c.curl_mime_name(field.?, field_name.ptr);
                const value = @field(params, struct_field.name);
                if (comptime isNumber(struct_field.type)) {
                    var number_buffer: [512]u8 = undefined;
                    var number = try std.fmt.bufPrintZ(&number_buffer, "{}", .{value});
                    _ = c.curl_mime_data(field.?, number.ptr, number.len);
                } else if (struct_field.type == @TypeOf(null)) {
                    _ = c.curl_mime_data(field.?, "null", 4);
                } else if (struct_field.type == bool) {
                    _ = c.curl_mime_data(field.?, if (value) "1" else "0", 1);
                } else if (struct_field.type == File) {
                    _ = c.curl_mime_filename(field.?, field_name);
                    _ = c.curl_mime_data(field.?, value.@"0".ptr, value.@"0".len);
                } else {
                    _ = c.curl_mime_data(field.?, value.ptr, value.len);
                }
            }
            _ = c.curl_easy_setopt(self.curl, c.CURLOPT_POST, @as(c_int, 1));
            _ = c.curl_easy_setopt(self.curl, c.CURLOPT_MIMEPOST, form);
        }

        const res = c.curl_easy_perform(self.curl);
        if (res != c.CURLE_OK) return error.BotNetworkError;
    }

    pub fn method(self: *Bot, name: []const u8, params: anytype) !Response {
        try self.request(name, params, true);
        return try Response.parse(self.allocator, self.data.items);
    }

    pub fn do(self: *Bot, name: []const u8, params: anytype) !void {
        try self.request(name, params, false);
    }

    pub fn poll(self: *Bot) !?Update {
        var res = self.method("getUpdates", .{
            .limit = 1,
            .offset = self.last_update,
        }) catch |err| switch (err) {
            error.BotNetworkError => return null,
            else => return err,
        };
        defer res.deinit();
        var updates_result = res.dot_token("result") orelse return null;
        if (updates_result.type != c.JSMN_ARRAY) return null;
        var updates_len = @as(usize, @intCast(updates_result.size));
        if (updates_len != 1) return null;

        var update_token = res.dot_token("result.0") orelse return error.OutOfIndexError;
        var update = try Response.parse(self.allocator, res.json[@as(usize, @intCast(update_token.start))..@as(usize, @intCast(update_token.end))]);

        self.last_update = try update.dot(usize, "update_id") + 1;
        return update;
    }

    pub fn deinit() void {
        c.curl_global_cleanup();
    }
};

fn memory_writer(contents: [*c]u8, size: usize, elems: usize, bot_instance: *Bot) callconv(.C) usize {
    const len = size * elems;
    bot_instance.data.appendSlice(bot_instance.allocator, contents[0..len]) catch return 0;
    return len;
}

fn null_writer(_: *anyopaque, size: usize, elems: usize, _: *anyopaque) callconv(.C) usize {
    return size * elems;
}

fn skipToken(tokens: []c.jsmntok_t, current: *usize) void {
    var pending: i64 = 1;
    while (true) {
        pending += tokens[current.*].size - 1;
        current.* += 1;
        if (pending <= 0) break;
    }
}

fn isNumber(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .Int, .ComptimeInt, .Float, .ComptimeFloat => true,
        else => false,
    };
}
