# GDNative YAWC Wrapper

This wraps the [yawc](https://github.com/infinitefield/yawc) crate to allow using it
as a WebSocket connection in Godot 3 projects.

The implementation is a bit barebones, since it's (currently) custom-built to be used
in place of Godot's built-in WebSocket for my
[Brotato Archipelago Client](https://github.com/SpenserHaddad/Brotato-ArchipelagoClient).
Godot 3's built-in WebSocket has quite a few limitations, in particular it does not
support permessage-deflate (RFC 7962), which Archipelago will eventually
require. It also is, in general, quite clunky to use (to be fair, it's meant for use in multiplayer
connections, not full-on data streaming). In particular, error handling is minimal, so
getting diagnostics about failed connections is difficult.

# Building

This project expects a custom Godot executable for building, see
[godot-rust's docs](https://godot-rust.github.io/gdnative-book/advanced/custom-godot.html)
for details. Building otherwise is a typical Rust project.

```bash
export GODOT_EXECUTABLE=<path_to_godot_executable>
cargo build
```

# Development

The created GDNative module exposes three classes:

- `AsyncExecutorDriver`, to set the executor for `async` tasks, which `yawc` makes heavy use of.
  This needs to be instantiated once in the project, but otherwise can be ignored.
- `GodotWebSocketFactory`, creates `GodotWebsocket` instances from a given URL. Has two
  public methods:
  - `create_websocket(url: String) -> GodotWebsocket`: Tries to connect to the given URL
    and creates a new `GodotWebsocket` instance if successful. (async)
  - `set_buffers(max_payload: usize: max_buffer: usisze)`: sets the maximum payload and
    buffer sizes for created WebSocket connections. See
    [yawc::Options::with_limits](https://docs.rs/yawc/latest/yawc/struct.Options.html#method.with_limits)
- `GodotWebSocket`, the actual WebSocket connection. Has the following public API:
  - `signal connection_closed(reason: String)`: Emitted when the connection is closed.
  - `signal data_received(data: String)`: Emitted when a message is received from the server.
    Only occurs during when calling `poll()`.
  - `connected`: Read-only property indicating if the connection is alive.
  - `url`: Read-only property of the URL of the connection.
  - `disconnect_from_host()`: Close the WebSocket connection.
  - `send(data: String)`: Send data over the WebSocket connection. (async)
  - `poll()`: Get and process any received messages from the server. (async)
    - This should be called every frame in a `_process` method from Godot.

Async methods need to be awaited from Godot with a `yield`, for example:

```gdscript
var websocket_factory = GodotWebSocketFactory.new()
var connect_state = websocket_factory.connect("wss://archipelago.gg:38281")
var connect_result = yield(connect_state, "completed")
```

The output of `yield` will have the return value of the method.

The [demo/](demo/) directory contains a Godot project that launches an AP client using
the wrapper for the underlying WebSocket connection. The folder [demo/ap](demo/ap/) has
all the pieces for handling the AP logic generically, and can be copied and used as a
starting point for any other AP client.

## Comments

### Why a Rust library instead of C/C++/etc.?

Personal preference and building a Rust library is much simpler, especially for multiple
platforms.

### Why are you using a custom build of gdnative (godot-rust)?

[godot-rust/gdnative](https://github.com/godot-rust/gdnative) is no longer maintained,
and the newer `godot-rust` is for Godot 4 only. However, `gdnative` did not build for
Rust 2024 without some changes, which meant I had to fork it and fix it myself.

There is no new features in the fork, only the bare minimum needed to make it compile.

### Why yawc over tungstenite?

tungstenite is the more popular Rust WebSocket library, but as of this writing it does
not support permessage-deflate, with an [open issue](https://github.com/snapview/tungstenite-rs/issues/2)
with little traction. yawc is the only Rust WebSocket library with permessage-deflate
that is actively maintained.

### Why not archipelago_rs?

[archipelago_rs](https://github.com/nex3/archipelago_rs) is a Rust library for the
Archipelago protocol, and could have been used. But, I only needed to update my
WebSocket implementation for Brotato, and this wrapper was less effort than rewriting
my existing client to follow the pattern archipelago_rs expects. Also, archipelago_rs
uses tungstentite for its WebSocket, so it wouldn't support permessage-deflate (see
above).
