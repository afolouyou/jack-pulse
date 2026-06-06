import std/unittest
import protocol
import server

suite "PulseAudio protocol tests":
  test "putString writes correct format":
    var w = initWriter()
    w.putString("hello")
    check w.buf.len == 1 + 5 + 1  # tag + chars + null
    check w.buf[0] == TAG_STRING
    # string bytes
    check w.buf[1..5] == @['h'.uint8, 'e'.uint8, 'l'.uint8, 'l'.uint8, 'o'.uint8]
    check w.buf[6] == 0

  test "handleSetClientName includes client_index for version >=13":
    # Ensure no previous clients
    clients.setLen(0)
    # Add a client with version >=13
    let fd = 123.cint
    discard findOrCreateClient(fd)  # creates client
    # set version manually, as if AUTH succeeded
    let idx = 0
    clients[idx].version = 13
    clients[idx].authorized = true
    # Build a SET_CLIENT_NAME payload: proplist with empty (P + N)
    var payload = @[TAG_PROPLIST.uint8, TAG_STRING_NULL.uint8]
    var tr = initReader(payload)
    # Reset captured output
    lastSentRaw = @[]
    # Call handler with tag=42 (arbitrary)
    handleSetClientName(fd, tr, 42)
    # Verify something was sent
    check lastSentRaw.len > 0
    # Decode frame header (first 20 bytes)
    let hdrLen = readU32BE(lastSentRaw, 0)   # length field
    check hdrLen == 15  # CMD_REPLY + tag + client_index
    let channel = readU32BE(lastSentRaw, 4)
    check channel == 0xFFFFFFFF'u32
    # Payload starts at offset 20
    let p = lastSentRaw[20..^1]
    # Expect three tagged u32: CMD_REPLY, tag, client_index
    check p.len == 15
    # Helper to read tagged u32 from payload
    proc readTaggedU32(data: openArray[uint8]; pos: int): (uint8, uint32) =
      let tag = data[pos]
      let val = readU32BE(data, pos+1)
      (tag, val)
    let (tg0, v0) = readTaggedU32(p, 0)
    let (tg1, v1) = readTaggedU32(p, 5)
    let (tg2, v2) = readTaggedU32(p, 10)
    check tg0 == TAG_U32 and v0 == CMD_REPLY.uint32
    check tg1 == TAG_U32 and v1 == 42'u32
    check tg2 == TAG_U32 and v2 == 0'u32   # client_index dummy

  test "read/write roundtrip using buildPacketFrame":
    var w = initWriter()
    w.putU32(PA_PROTOCOL_VERSION.uint32)
    let payload = w.buf  # 5 bytes: TAG_U32 + version
    check payload.len == 5
    check payload[0] == TAG_U32
    let fr = buildPacketFrame(w)  # the frame includes header + payload
    # decode
    let (hdr, decodedPayload, consumed) = readFramePayload(fr)
    check hdr.channel == 0xFFFFFFFF'u32
    check hdr.length == 5
    check decodedPayload == payload