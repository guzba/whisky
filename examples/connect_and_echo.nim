import whisky

let ws = newWebSocket("ws://...")
while true:
  echo ws.receiveMessage()
