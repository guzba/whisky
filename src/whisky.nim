import
  std/[base64, httpclient, monotimes, nativesockets, net, options, sha1, strutils,
    sysrand, times, uri]

export options

type
  WebSocket* = ref object
    socket*: Socket
    fragmented: bool
    pendingMessage: Message
    receiveBuffer: string
    maxMessageBytes: int

  Frame = object
    fin: bool
    opcode: uint8
    payload: string

  MessageKind* = enum
    TextMessage, BinaryMessage, Ping, Pong

  Message* = object
    kind*: MessageKind
    data*: string

const
  ReadBufferSize = 4096

proc close*(ws: WebSocket) {.raises: [].} =
  try:
    ws.socket.close()
  except:
    discard

proc fillReceiveBuffer(ws: WebSocket, size: int, deadline: MonoTime, timeout: int) =
  while ws.receiveBuffer.len < size:
    let remaining = if timeout < 0: -1
      else: max(0, (deadline - getMonoTime()).inMilliseconds.int)
    if remaining == 0 and (timeout > 0 or not ws.socket.hasDataBuffered):
      raise newException(TimeoutError, "WebSocket receive timed out")
    var bytes: array[ReadBufferSize, char]
    # A one-byte timed read cannot consume partial data before raising a timeout.
    let received = ws.socket.recv(addr bytes[0], 1, remaining)
    if received < 0:
      ws.socket.socketError(received)
    if received == 0:
      raise newException(CatchableError, "Error receiving WebSocket frame")
    var count = 1
    let capacity = min(bytes.len, size - ws.receiveBuffer.len)
    while count < capacity and ws.socket.hasDataBuffered:
      let received = ws.socket.recv(addr bytes[count], 1)
      if received < 0:
        ws.socket.socketError(received)
      if received == 0:
        raise newException(CatchableError, "Error receiving WebSocket frame")
      inc count
    let offset = ws.receiveBuffer.len
    ws.receiveBuffer.setLen(offset + count)
    copyMem(addr ws.receiveBuffer[offset], addr bytes[0], count)

proc receiveFrame(ws: WebSocket, deadline: MonoTime, timeout: int): Frame =
  ws.fillReceiveBuffer(2, deadline, timeout)
  let
    b0 = ws.receiveBuffer[0].uint8
    b1 = ws.receiveBuffer[1].uint8
    size = b1 and 0x7f
    headerLen = if size == 126: 4 elif size == 127: 10 else: 2
  if (b0 and 0x70) != 0:
    raise newException(CatchableError, "Bad WebSocket frame header")
  if (b1 and 0x80) != 0:
    raise newException(CatchableError, "Unexpected masked frame from server")
  ws.fillReceiveBuffer(headerLen, deadline, timeout)
  var payloadLen = size.uint64
  if headerLen > 2:
    payloadLen = 0
    for i in 2 ..< headerLen:
      payloadLen = (payloadLen shl 8) or ws.receiveBuffer[i].uint64
  if payloadLen > (int.high - headerLen).uint64 or
      (size == 126 and payloadLen < 126) or
      (size == 127 and payloadLen <= uint16.high.uint64):
    raise newException(CatchableError, "Invalid WebSocket payload length")
  result.fin = (b0 and 0x80) != 0
  result.opcode = b0 and 0x0f
  case result.opcode
  of 0x8, 0x9, 0xA:
    if not result.fin or payloadLen > 125:
      raise newException(CatchableError, "Received invalid WebSocket control frame")
  of 0x0, 0x1, 0x2:
    if result.opcode == 0 and not ws.fragmented:
      raise newException(CatchableError, "Unexpected WebSocket continuation frame")
    if result.opcode != 0 and ws.fragmented:
      raise newException(CatchableError, "Expected WebSocket continuation frame")
    let accumulated = if result.opcode == 0: ws.pendingMessage.data.len else: 0
    if payloadLen > (int.high - accumulated).uint64:
      raise newException(CatchableError, "Invalid WebSocket message length")
    if ws.maxMessageBytes > 0 and
        payloadLen > (ws.maxMessageBytes - accumulated).uint64:
      raise newException(CatchableError, "WebSocket message exceeds maxMessageBytes")
  else:
    raise newException(CatchableError, "Received invalid WebSocket frame")
  ws.fillReceiveBuffer(headerLen + payloadLen.int, deadline, timeout)
  result.payload = ws.receiveBuffer[headerLen ..< ws.receiveBuffer.len]
  ws.receiveBuffer.setLen(0)

proc receiveMessage*(ws: WebSocket, timeout = -1): Option[Message] {.gcsafe.} =
  ## Receives a message, preserving partial data across timeouts and controls.
  ## The timeout in milliseconds covers the entire call; -1 waits indefinitely.
  ## Close the connection after a protocol or message-size error.
  if timeout < -1:
    raise newException(ValueError, "WebSocket receive timeout must be at least -1")
  let deadline = getMonoTime() + initDuration(milliseconds = max(0, timeout))
  while true:
    var frame: Frame
    try:
      frame = ws.receiveFrame(deadline, timeout)
    except TimeoutError:
      return none(Message)

    case frame.opcode
    of 0x8, 0x9, 0xA:
      if frame.opcode == 0x8:
        raise newException(CatchableError, "WebSocket closed")
      return some(Message(kind: (if frame.opcode == 0x9: Ping else: Pong),
        data: move(frame.payload)))
    of 0x0:
      ws.pendingMessage.data.add(frame.payload)
      if frame.fin:
        ws.fragmented = false
        return some(move(ws.pendingMessage))
    of 0x1, 0x2:
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

proc newWebSocket*(url: string, headers: HttpHeaders = nil, timeout = -1,
    maxMessageBytes = 0): WebSocket =
  ## Opens a new WebSocket connection.
  ## Additional headers are copied; required upgrade headers take precedence.
  ## The HTTP connection timeout is in milliseconds; -1 waits indefinitely.
  ## maxMessageBytes limits complete incoming data messages; 0 is unlimited.
  if timeout < -1:
    raise newException(ValueError, "WebSocket connection timeout must be at least -1")
  if maxMessageBytes < 0:
    raise newException(ValueError, "maxMessageBytes must be nonnegative")

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

  var handshakeHeaders = newHttpHeaders()
  if headers != nil:
    for key, value in headers:
      handshakeHeaders.add(key, value)
  handshakeHeaders["Connection"] = "upgrade"
  handshakeHeaders["Upgrade"] = "websocket"
  handshakeHeaders["Sec-WebSocket-Key"] = base64.encode(websocketKey)
  handshakeHeaders["Sec-WebSocket-Version"] = $13

  let client = newHttpClient(headers = handshakeHeaders, timeout = timeout)
  var upgraded = false
  defer:
    if not upgraded:
      client.close()
  let response = client.get($uri)

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

  result = WebSocket(maxMessageBytes: maxMessageBytes)
  result.socket = client.getSocket()
  upgraded = true
