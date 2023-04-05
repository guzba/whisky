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

In a more complex situation, you can use threads to concurrently read and write to a WebSocket:

```nim
import whisky, std/os

let ws = newWebSocket("ws://...")

proc receiveThreadProc() =
  try:
    while true:
      echo ws.receiveMessage()
  except:
    echo getCurrentExceptionMsg()

var receiveThread: Thread[void]
createThread(receiveThread, receiveThreadProc)

for i in 0 ..< 4:
  echo "Sending a ping"
  ws.send("", Ping)
  sleep(2000)

# This causes any blocking send or receive calls to raise exceptions
ws.close()

echo "Done"
```

Check out the [examples/](https://github.com/guzba/whisky/tree/master/examples) folder for more sample code using Whisky.
