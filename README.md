# Whisky

`nimble install whisky`

![Github Actions](https://github.com/guzba/whisky/workflows/Github%20Actions/badge.svg)

[API reference](https://nimdocs.com/guzba/whisky)

Whisky is a blocking WebSocket client library that can be used in multi-threaded programs.

Whisky has no dependencies other than the Nim standard library.

## Using Whisky

Using Whisky can be as easy as:

```nim
import whisky

let ws = newWebSocket("ws://...")
while true:
  echo ws.receiveMessage()
```

This makes things like scripts that connect to a WebSocket server or writing tests for a WebSocket server very easy.

Check out the [examples/](https://github.com/guzba/whisky/tree/master/examples) folder for more sample code using Whisky.
