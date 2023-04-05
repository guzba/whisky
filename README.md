# Whisky

`nimble install whisky`

![Github Actions](https://github.com/guzba/whisky/workflows/Github%20Actions/badge.svg)

[API reference](https://nimdocs.com/guzba/whisky)

Whisky is a blocking WebSocket client. This library provides an alternative to async for situations where it is easier or more comfortable to write blocking code.

Whisky has no dependencies other than the Nim standard library.

Remember to include `-d:ssl` if connecting to `wss://` servers.

## Using Whisky

Using Whisky can be as easy as:

```nim
import whisky

let ws = newWebSocket("ws://...")
while true:
  echo ws.receiveMessage()
```

This makes things like scripts that connect to a WebSocket server or writing tests for a WebSocket server very easy. Whisky is very straightforward to use if you only need to receive messages from a WebSocket.

In more complex situations, you may need to send messages as well. In this case, you can use the timeout parameter of `receiveMessage` to give yourself opportunities to either send messages or check on other conditions:

```nim
import whisky

let ws = newWebSocket("ws://...")
while true:
  # This call will return with none(Message) if a message is not received
  # before the timeout in milliseconds has passed
  let msg = ws.receiveMessage(1000)
  if msg.isSome: # Did we receive a message?
    echo msg
  # Check if there is anything to send or whatever
  # Loop back to the top and go back to waiting for messages
```

A setup like this may not be ideal for every situation but it can work very well in many programs. If this does not meet your needs you can always use an async approach using one of the other WebSocket libraries out there.

Check out the [examples/](https://github.com/guzba/whisky/tree/master/examples) folder for more sample code using Whisky.

## Pro Tips

Whisky can be used in multi-threaded programs however each WebSocket should be owned and managed by just one thread. Reading and writing from separate threads is currently not supported.

Dedicating a thread to opening and reading/writing to a WebSocket can work well if you have an otherwise synchronous program and would prefer managing a thread over managing an async loop.
