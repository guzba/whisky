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
