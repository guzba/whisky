import whisky

let ws = newWebSocket("wss://stream2.pushbullet.com/websocket/test")
try:
  echo ws.receiveMessage()
  ws.send("", Ping)
  echo ws.receiveMessage()
finally:
  ws.close()
