import whisky

let ws = newWebSocket("wss://stream2.pushbullet.com/websocket/test")
echo ws.receiveMessage()
ws.send("", Ping)
echo ws.receiveMessage()
ws.close()
