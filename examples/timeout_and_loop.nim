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
