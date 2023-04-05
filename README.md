# Whisky

`nimble install whisky`

![Github Actions](https://github.com/guzba/whisky/workflows/Github%20Actions/badge.svg)

[API reference](https://nimdocs.com/guzba/whisky)

Whisky is a blocking WebSocket client. This library provides an alternative to async for situations where it is either easier or more comfortable to write blocking code.

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

In cases where you only only need to receive messages from a WebSocket as they arrive, this can be ideal. However, lets say you may need to send messages sometimes as well. In this case, you can use the timeout parameter of `receiveMessage` to give yourself opportunities to either send messages or check on other conditions:

```nim
import whisky, std/net

let ws = newWebSocket("ws://...")
while true:
  try:
    # Raises a TimeoutError if no message has been received before the timeout
    # in milliseconds has passed
    echo ws.receiveMessage(1000)
  except TimeoutError:
    discard
  # Check if there is anything to send or whatever
  # Loop back to the top and go back to waiting for messages
```

Check out the [examples/](https://github.com/guzba/whisky/tree/master/examples) folder for more sample code using Whisky.

## Pro Tips

While Whisky can be used in threaded programs, each WebSocket should be owned and managed by just one thread.
