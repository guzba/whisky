import
  std/[base64, httpcore, monotimes, net, os, osproc, sha1, streams, strutils, times],
  whisky

type
  Fixture = object
    process: Process
    url: string

const
  ReceiveTimeoutMs = 2_000
  PartialReadTimeoutMs = 40
  MaximumTimeoutElapsedMs = 1_000
  TrickleFragments = 20
  TrickleDelayMs = 25
  WholeCallTimeoutMs = 100
  LargePayloadSize = 17 * 1024 * 1024
  LargeReceiveTimeoutMs = 30_000

proc serverFrame(opcode: uint8, payload: string, final = true): string =
  let first = opcode or (if final: 0x80'u8 else: 0'u8)
  result.add(first.char)
  if payload.len <= 125:
    result.add(payload.len.char)
  elif payload.len <= uint16.high.int:
    result.add(126.char)
    for shift in countdown(8, 0, 8):
      result.add(((payload.len shr shift) and 0xff).char)
  else:
    result.add(127.char)
    for shift in countdown(56, 0, 8):
      result.add(((payload.len.uint64 shr shift) and 0xff).char)
  result.add(payload)

proc runFixture(mode: string) =
  let listener = newSocket()
  listener.bindAddr(Port(0), "127.0.0.1")
  listener.listen()
  stdout.writeLine(listener.getLocalAddr()[1].int)
  stdout.flushFile()
  var socket: Socket
  listener.accept(socket)
  defer:
    socket.close()
    listener.close()
  var headers = newHttpHeaders()
  let request = socket.recvLine()
  doAssert request.startsWith("GET ")
  while true:
    let line = socket.recvLine()
    if line.strip.len == 0:
      break
    let parts = line.split(':', 1)
    headers.add(parts[0], parts[1].strip())
  if mode == "stall":
    doAssert stdin.readLine() == "quit"
    return
  if mode == "auth":
    doAssert headers["Authorization"] == "Bearer test-token"
    doAssert headers["X-Custom"] == "test-value"
    doAssert headers["Connection"] == "upgrade"
    doAssert headers["Upgrade"] == "websocket"
    doAssert headers["Sec-WebSocket-Version"] == "13"
    doAssert decode(headers["Sec-WebSocket-Key"]).len == 16
  let
    key = headers["Sec-WebSocket-Key"]
    accept = encode(secureHash(key & "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").Sha1Digest)
  socket.send("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: " & accept & "\r\n\r\n")
  while true:
    let command = stdin.readLine()
    if command == "quit":
      break
    if command == "disconnect":
      return
    if command == "trickle":
      socket.send(serverFrame(1, "a", false))
      for i in 0 ..< TrickleFragments:
        sleep(TrickleDelayMs)
        socket.send(serverFrame(0, "b", i == TrickleFragments - 1))
      stdout.writeLine("sent")
      stdout.flushFile()
      continue
    socket.send(decode(command))
    stdout.writeLine("sent")
    stdout.flushFile()

proc startFixture(mode = "normal"): Fixture =
  result.process = startProcess(getAppFilename(), args = @["--fixture", mode],
    options = {poStdErrToStdOut})
  let port = result.process.outputStream.readLine()
  doAssert parseInt(port) > 0
  result.url = "ws://127.0.0.1:" & port

proc sendBytes(fixture: Fixture, data: string, wait = true) =
  fixture.process.inputStream.writeLine(encode(data))
  fixture.process.inputStream.flush()
  if wait:
    doAssert fixture.process.outputStream.readLine() == "sent"

proc close(fixture: Fixture) =
  fixture.process.inputStream.writeLine("quit")
  fixture.process.inputStream.flush()
  fixture.process.inputStream.close()
  let exitCode = fixture.process.waitForExit(5_000)
  doAssert exitCode == 0, fixture.process.outputStream.readAll()
  fixture.process.close()

proc expectMessage(ws: WebSocket, kind: MessageKind, data: string) =
  let received = ws.receiveMessage(ReceiveTimeoutMs)
  doAssert received.isSome
  doAssert received.get.kind == kind
  doAssert received.get.data == data

proc testMessages() =
  let
    fixture = startFixture()
    ws = newWebSocket(fixture.url)
  defer:
    ws.close()
    fixture.close()
  fixture.sendBytes(serverFrame(1, "hello") & serverFrame(2, "\x00\xff") & serverFrame(1, ""))
  ws.expectMessage(TextMessage, "hello")
  ws.expectMessage(BinaryMessage, "\x00\xff")
  ws.expectMessage(TextMessage, "")
  fixture.sendBytes(serverFrame(1, "abc", false) & serverFrame(0, "def", false) &
    serverFrame(0, "ghi") & serverFrame(1, "next"))
  ws.expectMessage(TextMessage, "abcdefghi")
  ws.expectMessage(TextMessage, "next")
  fixture.sendBytes(serverFrame(2, "\x01", false) & serverFrame(0, "\x02"))
  ws.expectMessage(BinaryMessage, "\x01\x02")

proc testControlFrames() =
  let
    fixture = startFixture()
    ws = newWebSocket(fixture.url)
  defer:
    ws.close()
    fixture.close()
  fixture.sendBytes(serverFrame(1, "abc", false) & serverFrame(9, "ping") &
    serverFrame(10, "pong") & serverFrame(0, "def"))
  ws.expectMessage(Ping, "ping")
  ws.expectMessage(Pong, "pong")
  ws.expectMessage(TextMessage, "abcdef")

proc testInvalidSequence(data: string) =
  let
    fixture = startFixture()
    ws = newWebSocket(fixture.url)
  defer:
    ws.close()
    fixture.close()
  fixture.sendBytes(data)
  var failed = false
  try:
    discard ws.receiveMessage(ReceiveTimeoutMs)
  except CatchableError:
    failed = true
  doAssert failed

proc expectTimeout(ws: WebSocket) =
  let
    started = getMonoTime()
    received = ws.receiveMessage(PartialReadTimeoutMs)
    elapsed = (getMonoTime() - started).inMilliseconds
  doAssert received.isNone
  doAssert elapsed >= PartialReadTimeoutMs div 2
  doAssert elapsed < MaximumTimeoutElapsedMs

proc testPartialFrame(payload: string, splits: seq[int]) =
  let
    fixture = startFixture()
    ws = newWebSocket(fixture.url)
    frame = serverFrame(1, payload)
  defer:
    ws.close()
    fixture.close()
  var start = 0
  for stop in splits:
    fixture.sendBytes(frame[start ..< stop])
    ws.expectTimeout()
    start = stop
  fixture.sendBytes(frame[start ..< frame.len], wait = false)
  ws.expectMessage(TextMessage, payload)
  doAssert fixture.process.outputStream.readLine() == "sent"

proc testContinuationTimeout() =
  let
    fixture = startFixture()
    ws = newWebSocket(fixture.url)
  defer:
    ws.close()
    fixture.close()
  fixture.sendBytes(serverFrame(1, "abc", false))
  ws.expectTimeout()
  fixture.sendBytes(serverFrame(9, "ping"))
  ws.expectMessage(Ping, "ping")
  fixture.sendBytes("\x80")
  ws.expectTimeout()
  fixture.sendBytes("\x03def")
  ws.expectMessage(TextMessage, "abcdef")

proc testWholeCallTimeout() =
  let
    fixture = startFixture()
    ws = newWebSocket(fixture.url)
  defer:
    ws.close()
    fixture.close()
  fixture.process.inputStream.writeLine("trickle")
  fixture.process.inputStream.flush()
  let
    started = getMonoTime()
    received = ws.receiveMessage(WholeCallTimeoutMs)
    elapsed = (getMonoTime() - started).inMilliseconds
  doAssert received.isNone
  doAssert elapsed < MaximumTimeoutElapsedMs
  ws.expectMessage(TextMessage, "a" & repeat('b', TrickleFragments))
  doAssert fixture.process.outputStream.readLine() == "sent"

proc testDisconnected(initialData: string) =
  let
    fixture = startFixture()
    ws = newWebSocket(fixture.url)
  defer:
    ws.close()
    fixture.process.close()
  if initialData.len > 0:
    fixture.sendBytes(initialData)
  fixture.process.inputStream.writeLine("disconnect")
  fixture.process.inputStream.flush()
  var failed = false
  try:
    discard ws.receiveMessage(ReceiveTimeoutMs)
  except CatchableError:
    failed = true
  doAssert failed
  doAssert fixture.process.waitForExit(5_000) == 0

proc testHandshakeHeaders() =
  let
    fixture = startFixture("auth")
    headers = newHttpHeaders({"Authorization": "Bearer test-token",
      "X-Custom": "test-value", "Connection": "caller-connection",
      "Upgrade": "caller-upgrade", "Sec-WebSocket-Key": "caller-key",
      "Sec-WebSocket-Version": "caller-version"})
    ws = newWebSocket(fixture.url, headers = headers, timeout = ReceiveTimeoutMs)
  defer:
    ws.close()
    fixture.close()
  doAssert headers["Connection"] == "caller-connection"
  doAssert headers["Upgrade"] == "caller-upgrade"
  doAssert headers["Sec-WebSocket-Key"] == "caller-key"
  doAssert headers["Sec-WebSocket-Version"] == "caller-version"
  fixture.sendBytes(serverFrame(1, "authenticated"))
  ws.expectMessage(TextMessage, "authenticated")

proc testConnectionTimeout() =
  let fixture = startFixture("stall")
  defer: fixture.close()
  let started = getMonoTime()
  var failed = false
  try:
    let ws = newWebSocket(fixture.url, timeout = PartialReadTimeoutMs)
    ws.close()
  except TimeoutError:
    failed = true
  let elapsed = (getMonoTime() - started).inMilliseconds
  doAssert failed
  doAssert elapsed < MaximumTimeoutElapsedMs

proc testMessageLimit() =
  let
    fixture = startFixture()
    ws = newWebSocket(fixture.url, maxMessageBytes = 6)
  defer:
    ws.close()
    fixture.close()
  fixture.sendBytes(serverFrame(1, "123456") & serverFrame(2, "123", false) &
    serverFrame(9, "control-payload") & serverFrame(0, "456") & serverFrame(1, ""))
  ws.expectMessage(TextMessage, "123456")
  ws.expectMessage(Ping, "control-payload")
  ws.expectMessage(BinaryMessage, "123456")
  ws.expectMessage(TextMessage, "")

proc testRejectedHeader(data: string, limit: int, expectedError: string) =
  let
    fixture = startFixture()
    ws = newWebSocket(fixture.url, maxMessageBytes = limit)
  defer:
    ws.close()
    fixture.close()
  fixture.sendBytes(data)
  var failure = ""
  try:
    discard ws.receiveMessage(PartialReadTimeoutMs)
  except CatchableError as error:
    failure = error.msg
  doAssert expectedError in failure

proc testUnlimitedMessage() =
  let
    fixture = startFixture()
    ws = newWebSocket(fixture.url)
    payload = repeat('x', LargePayloadSize)
  defer:
    ws.close()
    fixture.close()
  fixture.sendBytes(serverFrame(2, payload), wait = false)
  let received = ws.receiveMessage(LargeReceiveTimeoutMs)
  doAssert received.isSome
  doAssert received.get.kind == BinaryMessage
  doAssert received.get.data == payload
  doAssert fixture.process.outputStream.readLine() == "sent"

proc testInvalidOptions() =
  var failures = 0
  try:
    discard newWebSocket("ws://127.0.0.1:0", maxMessageBytes = -1)
  except ValueError:
    inc failures
  try:
    discard newWebSocket("ws://127.0.0.1:0", timeout = -2)
  except ValueError:
    inc failures
  let ws = WebSocket()
  try:
    discard ws.receiveMessage(-2)
  except ValueError:
    inc failures
  doAssert failures == 3

if paramCount() == 2 and paramStr(1) == "--fixture":
  runFixture(paramStr(2))
else:
  testMessages()
  testControlFrames()
  testInvalidSequence(serverFrame(0, "unexpected"))
  testInvalidSequence(serverFrame(1, "abc", false) & serverFrame(1, "unexpected"))
  testInvalidSequence(serverFrame(9, "ping", false))
  testInvalidSequence(serverFrame(9, repeat('x', 126)))
  testPartialFrame("abcdef", @[1, 3])
  testPartialFrame(repeat('x', 126), @[1, 3, 40])
  testPartialFrame(repeat('x', 65_536), @[1, 5, 32])
  testContinuationTimeout()
  testWholeCallTimeout()
  testDisconnected("")
  testDisconnected("\x81")
  testDisconnected("\x81\x05abc")
  testHandshakeHeaders()
  testConnectionTimeout()
  testMessageLimit()
  testRejectedHeader("\x81\x07", 6, "exceeds maxMessageBytes")
  testRejectedHeader(serverFrame(1, "abc", false) & "\x80\x04", 6,
    "exceeds maxMessageBytes")
  testRejectedHeader("\x81\x7f\x00\x00\x00\x01\x00\x00\x00\x00", 6,
    "exceeds maxMessageBytes")
  testRejectedHeader("\x81\x7f\x80\x00\x00\x00\x00\x00\x00\x00", 0,
    "Invalid WebSocket payload length")
  testRejectedHeader("\x81\x7f\x7f\xff\xff\xff\xff\xff\xff\xff", 0,
    "Invalid WebSocket payload length")
  testRejectedHeader("\x81\x7e\x00\x01", 0, "Invalid WebSocket payload length")
  testUnlimitedMessage()
  testInvalidOptions()
