import whisky, std/os

let ws = newWebSocket("wss://stream2.pushbullet.com/websocket/test")

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
