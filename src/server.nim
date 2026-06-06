import std/[logging, strformat, os, posix, times, strutils]
import protocol
import jacket
import jack_client
import ringbuffer

type
  Client* = object
    fd*: cint
    name*: string
    version*: uint32
    authorized*: bool
    streams*: seq[uint32]  # stream IDs owned by this client
    rbuf*: seq[uint8]      # partial read buffer

var
  serverFd: SocketHandle = SocketHandle(-1)
  clients*: seq[Client]
  nextStreamId: uint32 = 1

proc getSocketPath(): string =
  fmt"/tmp/pulse-{getuid()}/native"

proc readAll(fd: cint; buf: pointer; len: int): int =
  var pos = 0
  while pos < len:
    let n = posix.read(fd, cast[pointer](cast[uint](buf) + cast[uint](pos)), len - pos)
    if n <= 0:
      if n == 0: return -1
      if errno == EINTR: continue
      return -1
    pos += n
  return pos

proc writeAll(fd: cint; buf: pointer; len: int): int =
  var pos = 0
  while pos < len:
    let n = posix.write(fd, cast[pointer](cast[uint](buf) + cast[uint](pos)), len - pos)
    if n <= 0:
      if n == 0: return -1
      if errno == EINTR: continue
      return -1
    pos += n
  return pos

proc findOrCreateClient*(fd: cint): int =
  echo "findOrCreateClient: fd=", fd, " clients.len=", clients.len
  for i, c in clients:
    if c.fd == fd:
      echo "  found existing client at index ", i, " version=", c.version
      return i
  echo "  creating new client"
  clients.add(Client(fd: fd, authorized: false))
  echo "  new client at index ", clients.len - 1
  clients.len - 1

proc clientAt*(idx: int): var Client = clients[idx]

proc removeClient(fd: cint) =
  for i in 0 ..< clients.len:
    if clients[i].fd == fd:
      let c = clients[i]
      for sid in c.streams:
        jackRemoveStream(sid)
      clients.delete(i)
      discard close(fd.SocketHandle)
      return

when defined(test):
  var lastSentRaw*: seq[uint8] = @[]

proc sendRaw(fd: cint; data: openArray[uint8]) =
  when defined(test):
    lastSentRaw = @data
  else:
    echo "sendRaw: ", data.len, " bytes to fd ", fd
    var hex = ""
    for i in 0 ..< min(data.len, 300):
      hex.add(data[i].int.toHex(2)); hex.add(" ")
    echo "  ", hex
    discard writeAll(fd, data[0].unsafeAddr, data.len)

proc sendPacket(fd: cint; tw: var TagWriter) =
  let frame = buildPacketFrame(tw)
  echo "sendPacket: frame=", frame.len, " bytes"
  sendRaw(fd, frame)

proc sendError(fd: cint; tag: uint32; code: uint32) =
  var tw = initWriter()
  tw.putU32(CMD_ERROR.uint32)
  tw.putU32(tag)
  tw.putU32(code)
  sendPacket(fd, tw)

proc sendReply(fd: cint; tag: uint32; replyTW: var TagWriter) =
  var tw = initWriter()
  tw.putU32(CMD_REPLY.uint32)
  tw.putU32(tag)
  # Append reply body
  for b in replyTW.buf: tw.buf.add b
  sendPacket(fd, tw)

proc sendSimpleReply(fd: cint; tag: uint32) =
  var empty = initWriter()
  sendReply(fd, tag, empty)

proc handleAuth(fd: cint; tr: var TagReader; cmdTag: uint32) =
  let rawVersion = tr.getU32()
  let clientVersion = rawVersion and 0x00FFFFFF'u32  # lower 24 bits = actual protocol version
  let flags = rawVersion and 0xFF000000'u32           # upper 8 bits = SHM/MEMFD flags
  let cookie = tr.getArbitrary(PA_NATIVE_COOKIE_LENGTH)
  # Negotiate: use minimum of our version and client's version
  let negotiatedVersion = min(PA_PROTOCOL_VERSION.uint32, clientVersion)
  echo "handleAuth: clientVersion=", clientVersion, " flags=", flags, " negotiated=", negotiatedVersion
  let idx = findOrCreateClient(fd)
  clients[idx].version = negotiatedVersion
  clients[idx].authorized = true
  echo "handleAuth: stored version=", clients[idx].version

  var reply = initWriter()
  reply.putU32(PA_PROTOCOL_VERSION.uint32)
  sendReply(fd, cmdTag, reply)

proc handleSetClientName*(fd: cint; tr: var TagReader; cmdTag: uint32) =
  let idx = findOrCreateClient(fd)
  echo "SET_CLIENT_NAME: clients[", idx, "].version = ", clients[idx].version
  if clients[idx].version >= 13:
    discard tr.getTag()  # skip proplist tag P
    while not tr.eof():
      discard tr.getTag()
  else:
    let name = tr.getString()
    if name != "": clients[idx].name = name
  var reply = initWriter()
  if clients[idx].version >= 13:
    reply.putU32(0)  # client_index (dummy)
    echo "SET_CLIENT_NAME: adding client_index to reply"
  else:
    echo "SET_CLIENT_NAME: NOT adding client_index (version < 13)"
  sendReply(fd, cmdTag, reply)

proc handleCreatePlaybackStream(fd: cint; tr: var TagReader; cmdTag: uint32) =
  let idx = findOrCreateClient(fd)
  if not clients[idx].authorized:
    sendError(fd, cmdTag, ERR_ACCESS)
    return

  let ss = tr.getSampleSpec()
  let cm = tr.getChannelMap()
  let sinkIdx = tr.getU32()
  let sinkName = tr.getString()
  let maxLength = tr.getU32()
  let corked = tr.getBoolean()
  let tlengthRaw = tr.getU32()
  let prebufRaw = tr.getU32()
  let minreqRaw = tr.getU32()
  let syncid = tr.getU32()
  let vol = tr.getCvolume()

  # Skip v12+ flags
  if clients[idx].version >= 12:
    discard tr.getBoolean()  # no_remap
    discard tr.getBoolean()  # no_remix
    discard tr.getBoolean()  # fix_format
    discard tr.getBoolean()  # fix_rate
    discard tr.getBoolean()  # fix_channels
    discard tr.getBoolean()  # no_move
    discard tr.getBoolean()  # variable_rate

  # Skip v13+ fields
  if clients[idx].version >= 13:
    discard tr.getBoolean()  # muted
    discard tr.getBoolean()  # adjust_latency
    discard tr.getTag()  # proplist tag 'P' - skip entire proplist by reading to end

  let clientName = clients[idx].name

  let streamId = nextStreamId
  inc nextStreamId

  if not jackAddStream(streamId, ss.ch):
    sendError(fd, cmdTag, ERR_NOTIMPLEMENTED)
    return

  # Store sample spec on the stream for deinterleave
  for st in mitems(jack.streams):
    if st.id == streamId:
      st.sampleChannels = ss.ch
      st.sampleRate = ss.rate
      break

  clients[idx].streams.add(streamId)

  # Replace INVALID_INDEX with sensible defaults
  let defaultTlength = 65536'u32
  let defaultMinreq = 16384'u32
  let defaultPrebuf = 65536'u32
  let defaultMaxlen = 131072'u32

  let actualMaxlen = if maxLength == PA_INVALID_INDEX: defaultMaxlen else: maxLength
  let actualTlength = if tlengthRaw == PA_INVALID_INDEX: defaultTlength else: tlengthRaw
  let actualPrebuf = if prebufRaw == PA_INVALID_INDEX: defaultPrebuf else: prebufRaw
  let actualMinreq = if minreqRaw == PA_INVALID_INDEX: defaultMinreq else: minreqRaw

  # Build reply for version 13
  var reply = initWriter()
  reply.putU32(streamId)              # stream_index
  reply.putU32(streamId)              # sink_input_index (same)
  reply.putU32(actualTlength)         # missing (tell client how much to send)
  # v9+ buffer attrs
  reply.putU32(actualMaxlen)          # maxlength
  reply.putU32(actualTlength)         # tlength
  reply.putU32(actualPrebuf)          # prebuf
  reply.putU32(actualMinreq)          # minreq
  # v12+ sample spec, channel map, sink info
  reply.putSampleSpec(ss.fmt, ss.ch, ss.rate)
  reply.putChannelMap(cm)
  reply.putU32(0)                     # sink_index (our dummy)
  reply.putString("jack-pulse")       # sink_name
  reply.putBoolean(false)             # suspended
  # v13+ configured_sink_latency
  reply.putUsec(0)                    # 0 latency

  sendReply(fd, cmdTag, reply)

proc handleDrainPlaybackStream(fd: cint; tr: var TagReader; cmdTag: uint32) =
  discard tr.getU32()  # stream_id
  sendSimpleReply(fd, cmdTag)

proc handleGetPlaybackLatency(fd: cint; tr: var TagReader; cmdTag: uint32) =
  let sId = tr.getU32()
  let reqTv = tr.getTimeval()

  # Compute actual latency from ring buffer fill
  var sinkUsec: uint64 = 0
  var playing = false
  for st in mitems(jack.streams):
    if st.id == sId and st.rings.len > 0 and st.rings[0] != nil:
      let fill = ringAvail(st.rings[0])
      let rate = if st.sampleRate > 0: st.sampleRate.uint64 else: 48000'u64
      sinkUsec = (fill.uint64 * 1_000_000'u64) div rate
      playing = not st.corked and st.active
      break

  let nowEpoch = epochTime()
  let sec = int(nowEpoch).uint32
  let usec = int((nowEpoch - float(int(nowEpoch))) * 1_000_000).uint32

  var reply = initWriter()
  reply.putUsec(sinkUsec)          # sink_usec
  reply.putUsec(0)                 # source_usec
  reply.putBoolean(playing)        # playing
  reply.putTimeval(reqTv.sec, reqTv.usec)  # requested timestamp
  reply.putTimeval(sec, usec)      # now
  reply.putS64(0)                  # write_index
  reply.putS64(0)                  # read_index
  # v13+
  reply.putU64(0)                  # underrun_for
  reply.putU64(0)                  # playing_for

  sendReply(fd, cmdTag, reply)

proc handleFlushPlaybackStream(fd: cint; tr: var TagReader; cmdTag: uint32) =
  let sId = tr.getU32()  # stream_id
  jackStreamClear(sId)
  sendSimpleReply(fd, cmdTag)

proc handleCorkPlaybackStream(fd: cint; tr: var TagReader; cmdTag: uint32) =
  let sId = tr.getU32()   # stream_id
  let cork = tr.getBoolean()  # cork
  for st in mitems(jack.streams):
    if st.id == sId:
      st.corked = cork
      break
  sendSimpleReply(fd, cmdTag)

proc handleSubscribe(fd: cint; tr: var TagReader; cmdTag: uint32) =
  discard tr.getU32()  # mask
  sendSimpleReply(fd, cmdTag)

proc handleStat(fd: cint; tr: var TagReader; cmdTag: uint32) =
  var reply = initWriter()
  reply.putU32(0)  # n_allocated
  reply.putU32(0)  # allocated_size
  reply.putU32(0)  # n_accumulated
  reply.putU32(0)  # accumulated_size
  reply.putU32(0)  # scache_size
  sendReply(fd, cmdTag, reply)

proc handleGetServerInfo(fd: cint; tr: var TagReader; cmdTag: uint32) =
  var reply = initWriter()
  let jackVer = $getVersionString()
  echo "JACK version: ", jackVer
  reply.putString("PulseAudio (on JACK " & jackVer & ")")  # server_name
  reply.putString("7.0")                           # server_version
  reply.putString("jack-pulse")                    # user_name
  reply.putString("linux")                         # host_name (before sample_spec!)
  reply.putSampleSpec(PA_SAMPLE_S16LE.uint8, 2, 44100)  # default sample spec
  reply.putString("jack-pulse")          # default sink
  reply.putString("jack-pulse")          # default source
  reply.putU32(0)                        # cookie
  let idx = findOrCreateClient(fd)
  echo "GET_SERVER_INFO: client version=", clients[idx].version
  if clients[idx].version >= 15:
    reply.putChannelMap(@[uint8 0, 1])   # channel_map (v15+)
    echo "  added channel_map"
  sendReply(fd, cmdTag, reply)

proc handleGetSinkInfo(fd: cint; tr: var TagReader; cmdTag: uint32) =
  let name = tr.getString()
  var reply = initWriter()
  reply.putU32(0)              # index
  reply.putString("jack-pulse")  # name
  reply.putString("jack-pulse")  # description
  reply.putSampleSpec(PA_SAMPLE_S16LE.uint8, 2, 44100)
  reply.putChannelMap(@[uint8 0, 1])
  reply.putU32(0)  # owner_module
  reply.putCvolume(2, [uint32 0x10000, 0x10000])
  reply.putBoolean(false)  # mute
  reply.putU32(0)          # monitor_source
  reply.putString("")      # monitor_source_name
  reply.putU64(0)          # latency
  reply.putString("")      # driver
  reply.putU32(0)          # flags
  reply.putU32(0)          # configured_latency (usec)
  reply.putVolume(0x10000)  # base_volume
  reply.putU32(0)          # state (suspend)
  reply.putU64(0)          # volume_writable
  reply.putU32(0)          # n_volume_steps
  reply.putU32(0)          # card
  reply.putU32(0)          # n_ports
  reply.putString("")      # active_port
  reply.putU8(0)           # n_formats
  if name == "":
    # This was a list request
    discard
  sendReply(fd, cmdTag, reply)

proc handleGetSinkInfoList(fd: cint; tr: var TagReader; cmdTag: uint32) =
  # Sending 1 sink
  var reply = initWriter()
  reply.putU32(1)  # count
  reply.putU32(0)              # index
  reply.putString("jack-pulse")  # name
  reply.putString("Jack-Pulse Sink")  # description
  reply.putSampleSpec(PA_SAMPLE_S16LE.uint8, 2, 44100)
  reply.putChannelMap(@[uint8 0, 1])
  reply.putU32(PA_INVALID_INDEX)  # owner_module
  reply.putCvolume(2, [uint32 0x10000, 0x10000])
  reply.putBoolean(false)  # mute
  reply.putU32(0)          # monitor_source
  reply.putString("")      # monitor_source_name
  reply.putU64(0)          # latency
  reply.putString("jack-pulse")  # driver
  reply.putU32(0)          # flags
  reply.putU32(0)          # configured_latency
  reply.putVolume(0x10000)  # base_volume
  reply.putU32(0)          # state
  reply.putU64(0)          # volume_writable(?)
  reply.putU32(0)          # n_volume_steps
  reply.putU32(PA_INVALID_INDEX)  # card
  reply.putU32(0)          # n_ports
  reply.putString("")      # active_port
  reply.putU8(0)           # n_formats
  sendReply(fd, cmdTag, reply)

proc handleGetSourceInfoList(fd: cint; tr: var TagReader; cmdTag: uint32) =
  # Return empty source list
  var reply = initWriter()
  reply.putU32(0)  # count (no sources)
  sendReply(fd, cmdTag, reply)

proc handleMemblock(fd: cint; streamId: uint32; data: openArray[uint8]) =
  if data.len < 2: return
  let frameSize = 2  # S16LE = 2 bytes per sample
  let totalSamples = data.len div frameSize
  if totalSamples == 0: return
  # Find stream for channel count
  var nCh = 1'u8
  for st in mitems(jack.streams):
    if st.id == streamId and st.sampleChannels > 0:
      nCh = st.sampleChannels
      break
  let nFrames = totalSamples div int(nCh)
  if nFrames == 0: return
  let maxFrames = min(nFrames, 8192)
  # Deinterleave: allocate per-channel float32 buffers
  var chBuf: array[8, array[8192, float32]]
  for i in 0 ..< maxFrames:
    for ch in 0 ..< int(nCh):
      let srcIdx = (i * int(nCh) + ch) * 2
      if srcIdx + 1 >= data.len: break
      let lo = data[srcIdx].uint16
      let hi = data[srcIdx + 1].uint16
      let sample = int16((hi shl 8) or lo)
      chBuf[ch][i] = float32(sample) / 32768.0
  for ch in 0 ..< int(nCh):
    jackWriteAudio(streamId, ch, chBuf[ch][0].addr, maxFrames.uint32)

proc handleFrame(fd: cint; hdr: FrameHdr; payload: seq[uint8]) =
  echo "handleFrame: channel=", hdr.channel, " payload.len=", payload.len
  if hdr.channel == 0xFFFFFFFF'u32:
    var hex = ""
    for i in 0 ..< min(payload.len, 400):
      hex.add(payload[i].int.toHex(2)); hex.add(" ")
    echo "  payload: ", hex
    var pkt = initReader(payload)
    let cmd = pkt.getU32()
    let tag = pkt.getU32()
    echo "  cmd=", cmd, " tag=", tag

    case cmd:
    of CMD_AUTH.uint32:
      echo "  -> AUTH"
      handleAuth(fd, pkt, tag)
    of CMD_SET_CLIENT_NAME.uint32:
      echo "  -> SET_CLIENT_NAME"
      handleSetClientName(fd, pkt, tag)
    of CMD_CREATE_PLAYBACK_STREAM.uint32:
      echo "  -> CREATE_PLAYBACK_STREAM"
      handleCreatePlaybackStream(fd, pkt, tag)
    of CMD_DRAIN_PLAYBACK_STREAM.uint32:
      echo "  -> DRAIN_PLAYBACK_STREAM"
      handleDrainPlaybackStream(fd, pkt, tag)
    of CMD_GET_PLAYBACK_LATENCY.uint32:
      echo "  -> GET_PLAYBACK_LATENCY"
      handleGetPlaybackLatency(fd, pkt, tag)
    of CMD_FLUSH_PLAYBACK_STREAM.uint32:
      echo "  -> FLUSH_PLAYBACK_STREAM"
      handleFlushPlaybackStream(fd, pkt, tag)
    of CMD_CORK_PLAYBACK_STREAM.uint32:
      echo "  -> CORK_PLAYBACK_STREAM"
      handleCorkPlaybackStream(fd, pkt, tag)
    of CMD_SUBSCRIBE.uint32:
      echo "  -> SUBSCRIBE"
      handleSubscribe(fd, pkt, tag)
    of CMD_STAT.uint32:
      echo "  -> STAT"
      handleStat(fd, pkt, tag)
    of CMD_GET_SERVER_INFO.uint32:
      echo "  -> GET_SERVER_INFO"
      handleGetServerInfo(fd, pkt, tag)
    of CMD_GET_SINK_INFO.uint32:
      echo "  -> GET_SINK_INFO"
      handleGetSinkInfo(fd, pkt, tag)
    of CMD_GET_SINK_INFO_LIST.uint32:
      echo "  -> GET_SINK_INFO_LIST"
      handleGetSinkInfoList(fd, pkt, tag)
    of CMD_GET_SOURCE_INFO_LIST.uint32:
      echo "  -> GET_SOURCE_INFO_LIST"
      handleGetSourceInfoList(fd, pkt, tag)
    of CMD_REGISTER_MEMFD_SHMID.uint32:
      echo "  -> REGISTER_MEMFD_SHMID"
      sendSimpleReply(fd, tag)
    else:
      echo "  -> UNKNOWN command ", cmd
      sendError(fd, tag, ERR_NOTIMPLEMENTED)
  else:
    echo "  -> MEMBLOCK channel=", hdr.channel
    handleMemblock(fd, hdr.channel, payload)

proc readU32BE*(data: openArray[uint8]; pos: int): uint32 =
  (data[pos].uint32 shl 24) or (data[pos+1].uint32 shl 16) or (data[pos+2].uint32 shl 8) or data[pos+3].uint32

proc readFramePayload*(data: openArray[uint8]): tuple[hdr: FrameHdr; payload: seq[uint8]; consumed: int] =
  if data.len < 20:
    return (FrameHdr(), @[], 0)
  let lenV = readU32BE(data, 0)
  let ch = readU32BE(data, 4)
  let oh = readU32BE(data, 8)
  let ol = readU32BE(data, 12)
  let fl = readU32BE(data, 16)
  let hdr = FrameHdr(length: lenV, channel: ch, offsetHi: oh, offsetLo: ol, flags: fl)
  let total = 20 + int(lenV)
  if data.len < total:
    return (FrameHdr(), @[], 0)
  var payload = newSeq[uint8](int(lenV))
  for i in 0 ..< int(lenV):
    payload[i] = data[20 + i]
  (hdr, payload, total)

proc handleClient(fd: cint) =
  var cIdx = -1
  for i in 0 ..< clients.len:
    if clients[i].fd == fd:
      cIdx = i
      break
  if cIdx < 0:
    removeClient(fd)
    return
  var buf: array[65536, uint8]
  let n = posix.read(fd, buf[0].addr, 65536)
  if n <= 0:
    removeClient(fd)
    return
  echo "read ", n, " bytes from fd ", fd
  clients[cIdx].rbuf.add(buf[0 ..< n])
  var data = clients[cIdx].rbuf
  while true:
    let (hdr, payload, consumed) = readFramePayload(data)
    if consumed == 0:
      echo "not enough data for full frame, have ", data.len, " bytes"
      break
    echo "got frame: channel=", hdr.channel, " length=", hdr.length, " payload=", payload.len
    handleFrame(fd, hdr, payload)
    if consumed < data.len:
      data = data[consumed .. ^1]
    else:
      data = @[]
  clients[cIdx].rbuf = data

proc createSocket(): SocketHandle =
  let path = getSocketPath()
  let dir = path.parentDir()
  if dirExists(dir):
    discard tryRemoveFile(path)
  else:
    createDir(dir)
  let fd = socket(AF_UNIX, SOCK_STREAM, 0)
  if fd == SocketHandle(-1):
    error "socket: " & $strerror(errno)
    return SocketHandle(-1)
  var addrIn: SockAddr_un
  addrIn.sun_family = TSa_Family(AF_UNIX)
  var i = 0
  for c in path:
    addrIn.sun_path[i] = c
    inc i
  addrIn.sun_path[i] = '\0'
  let bindLen = sizeof(SockAddr_un) - sizeof(addrIn.sun_path) + i + 1
  if bindSocket(fd, cast[ptr SockAddr](addrIn.addr), bindLen.SockLen) < 0.cint:
    error "bind: " & $strerror(errno)
    discard close(fd); return SocketHandle(-1)
  discard chmod(cstring(path), Mode(0o777))
  if listen(fd, 5) < 0.cint:
    error "listen: " & $strerror(errno)
    discard close(fd); return SocketHandle(-1)
  discard chmod(cstring(path), Mode(0o777))

  if listen(fd, 5) < 0.cint:
    error "listen: " & $strerror(errno)
    discard close(fd); return SocketHandle(-1)
  info fmt"Listening on {path}"
  fd

proc run*() =
  serverFd = createSocket()
  if serverFd == SocketHandle(-1): quit(1)

  var rfds: TFdSet
  while true:
    FD_ZERO(rfds)
    FD_SET(serverFd, rfds)
    var maxFd = serverFd.cint
    var fds: seq[SocketHandle] = @[]
    for c in clients:
      FD_SET(c.fd.SocketHandle, rfds)
      fds.add(c.fd.SocketHandle)
      if c.fd.cint > maxFd: maxFd = c.fd.cint

    let ret = select(maxFd + 1, rfds.addr, nil, nil, nil)
    if ret < 0.cint:
      if cint(errno) == EINTR: continue
      break

    if FD_ISSET(serverFd, rfds) != 0.cint:
      var addrIn: SockAddr_un
      var addrLen = SockLen(sizeof(SockAddr_un))
      let clientFd = accept(serverFd, cast[ptr SockAddr](addrIn.addr), addrLen.addr)
      if clientFd != SocketHandle(-1):
        discard findOrCreateClient(clientFd.cint)

    for fd in fds:
      if FD_ISSET(fd, rfds) != 0.cint:
        handleClient(fd.cint)

proc shutdown*() =
  if serverFd != SocketHandle(-1): discard close(serverFd)
  for c in clients: discard close(c.fd.SocketHandle)
  clients.setLen(0)
  disconnectJack()
