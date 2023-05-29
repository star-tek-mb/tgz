# Overview

tgz - zig library for telegram bots

# Goals

- be fast at runtime

- be fast at comptime

Zig's current http/https client API is unstable. And also requires a lot of time to compile.

Initial idea was to parse JSON to structs, but it have been hurting compile time.

So decision was made to dot access to fields of json.

If we have following json:

```json
{
    "ok": true,
    "result": [
        {
            "name": "string",
        }
    ]
}
```

You can query like this:

```
"ok" - true
"result" - length of array
"result.0" - length of object
"result.0.name" - "string"
```

# Usage

```zig
// do request without caring of response
try bot.do("sendPhoto", .{
    .chat_id = chat_id,
    .photo = File{photo},
    .caption = text,
});
// do request and get json data
var res = try bot.method("getMe", .{});
defer res.deinit();
var is_bot = try res.dot(bool, "result.is_bot");
```

# Example

See `main.zig`
