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
