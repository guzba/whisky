import
  std/[base64, httpclient, nativesockets, net, options, sha1, strutils, sysrand, uri]

export options

type
  WebSocket* = ref object
    socket*: Socket
    fragmented: bool
    pendingMessage: Message

  Frame = object
    fin: bool
    opcode: uint8
    payload: string

  MessageKind* = enum
    TextMessage, BinaryMessage, Ping, Pong

  Message* = object
    kind*: MessageKind
    data*: string

proc close*(ws: WebSocket) {.raises: [].} =
  try:
    ws.socket.close()
  except:
    discard

proc receiveFrame(ws: WebSocket, timeout = -1): Frame =
  let b = ws.socket.recv(2, timeout)
  if b.len != 2:
    raise newException(CatchableError, "Error receiving WebSocket frame")

  let
    b0 = b[0].uint8
    b1 = b[1].uint8
    fin = (b0 and 0b10000000) != 0
    rsv1 = b0 and 0b01000000
    rsv2 = b0 and 0b00100000
    rsv3 = b0 and 0b00010000
    opcode = b0 and 0b00001111

  if rsv1 != 0 or rsv2 != 0 or rsv3 != 0:
    raise newException(CatchableError, "Bad WebSocket frame header")

  if (b1 and 0b10000000) != 0:
    raise newException(CatchableError, "Unexpected masked frame from server")

  var payloadLen = (b1 and 0b01111111).int
  if payloadLen <= 125:
    discard
  elif payloadLen == 126:
    var
      buf = ws.socket.recv(2)
      l: uint16
    copyMem(l.addr, buf[0].addr, 2)
    payloadLen = nativesockets.htons(l).int
  else:
    var
      buf = ws.socket.recv(8)
      l: uint32
    copyMem(l.addr, buf[4].addr, 4)
    payloadLen = nativesockets.htonl(l).int

  result.fin = fin
  result.opcode = opcode

  if payloadLen > 0:
    var buf = ws.socket.recv(payloadLen)
    if buf.len == 0 or buf.len != payloadLen:
      raise newException(CatchableError, "Error receiving WebSocket frame")
    result.payload &= buf

proc receiveMessage*(ws: WebSocket, timeout = -1): Option[Message] {.gcsafe.} =
  ## Receives a message, preserving fragmented data between control messages.
  while true:
    var frame: Frame
    try:
      frame = ws.receiveFrame(timeout)
    except TimeoutError:
      return none(Message)

    case frame.opcode
    of 0x8, 0x9, 0xA:
      if not frame.fin or frame.payload.len > 125:
        raise newException(CatchableError, "Received invalid WebSocket control frame")
      if frame.opcode == 0x8:
        raise newException(CatchableError, "WebSocket closed")
      return some(Message(kind: (if frame.opcode == 0x9: Ping else: Pong),
        data: move(frame.payload)))
    of 0x0:
      if not ws.fragmented:
        raise newException(CatchableError, "Unexpected WebSocket continuation frame")
      ws.pendingMessage.data.add(frame.payload)
      if frame.fin:
        ws.fragmented = false
        return some(move(ws.pendingMessage))
    of 0x1, 0x2:
      if ws.fragmented:
        raise newException(CatchableError, "Expected WebSocket continuation frame")
      let message = Message(kind: (if frame.opcode == 0x1: TextMessage else: BinaryMessage),
        data: move(frame.payload))
      if frame.fin:
        return some(message)
      ws.pendingMessage = message
      ws.fragmented = true
    else:
      raise newException(CatchableError, "Received invalid WebSocket frame")

proc encodeFrame(opcode: uint8, payload: sink string): string =
  assert (opcode and 0b11110000) == 0

  result.add cast[char](0b10000000 or opcode)

  # Add b1, the length and mask flag
  if payload.len <= 125:
    result.add (0b10000000 or payload.len.uint8).char
  elif payload.len <= uint16.high.int:
    result.add (0b10000000 or 126).char
    result.setLen(result.len + 2)
    var l = cast[uint16](payload.len).htons
    copyMem(result[result.len - 2].addr, l.addr, 2)
  else:
    result.add (0b10000000 or 127).char
    result.setLen(result.len + 8)
    var l = cast[uint32](payload.len).htonl
    copyMem(result[result.len - 4].addr, l.addr, 4)

  var mask = newString(4)
  if not urandom(mask.toOpenArrayByte(0, 3)):
    raise newException(CatchableError, "Failed to generate mask")

  result.add mask

  # Mask the payload
  for i in 0 ..< payload.len:
    let j = i mod 4
    payload[i] = (payload[i].uint8 xor mask[j].uint8).char

  result.add payload

proc send*(ws: WebSocket, data: sink string, kind = TextMessage) {.gcsafe.} =
  ws.socket.send(case kind:
    of TextMessage:
      encodeFrame(0x1, data)
    of BinaryMessage:
      encodeFrame(0x2, data)
    of Ping:
      encodeFrame(0x9, data)
    of Pong:
      encodeFrame(0xA, data)
  )

proc newWebSocket*(url: string): WebSocket =
  ## Opens a new WebSocket connection.

  var uri = parseUri(url)
  case uri.scheme
    of "wss":
      uri.scheme = "https"
    of "ws":
      uri.scheme = "http"
    of "http", "https":
      discard
    else:
      raise newException(
        CatchableError,
        "Scheme " & uri.scheme & "not supported"
      )

  var websocketKey = newString(16)
  if not urandom(websocketKey.toOpenArrayByte(0, 15)):
    raise newException(CatchableError, "Failed to generate WebSocket key")

  var headers = newHttpHeaders()
  headers["Connection"] = "upgrade"
  headers["Upgrade"] = "websocket"
  headers["Sec-WebSocket-Key"] = base64.encode(websocketKey)
  headers["Sec-WebSocket-Version"] = $13

  let
    client = newHttpClient(headers = headers)
    response = client.get($uri)

  if response.code != Http101:
    raise newException(
      CatchableError,
      "Invalid WebSocket upgrade response code"
    )

  if cmpIgnoreCase(response.headers.getOrDefault("Connection"), "upgrade") != 0:
    raise newException(
      CatchableError,
      "WebSocket upgrade response missing Connection header"
    )

  if cmpIgnoreCase(response.headers.getOrDefault("Upgrade"), "websocket") != 0:
    raise newException(
      CatchableError,
      "WebSocket upgrade response missing Upgrade header"
    )

  let
    verify = response.headers["Sec-WebSocket-Accept"]
    hash = base64.encode(secureHash(
      base64.encode(websocketKey) & "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    ).Sha1Digest)
  if verify != hash:
    raise newException(
      CatchableError,
      "WebSocket upgrade response verification failed"
    )

  result = WebSocket()
  result.socket = client.getSocket()
