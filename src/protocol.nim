import std/endians

const
  PA_PROTOCOL_VERSION* = 13  # since 2013
  PA_NATIVE_COOKIE_LENGTH* = 256
  FRAME_SIZE_MAX_ALLOW* = 1024 * 1024 * 16

  CMD_ERROR* = 0
  CMD_REPLY* = 2
  CMD_CREATE_PLAYBACK_STREAM* = 3
  CMD_DELETE_PLAYBACK_STREAM* = 4
  CMD_DRAIN_PLAYBACK_STREAM* = 12
  CMD_AUTH* = 8
  CMD_SET_CLIENT_NAME* = 9
  CMD_STAT* = 13
  CMD_GET_PLAYBACK_LATENCY* = 14
  CMD_CREATE_UPLOAD_STREAM* = 15
  CMD_GET_SERVER_INFO* = 20
  CMD_GET_SINK_INFO* = 21
  CMD_GET_SINK_INFO_LIST* = 22
  CMD_GET_SOURCE_INFO* = 23
  CMD_GET_SOURCE_INFO_LIST* = 24
  CMD_SUBSCRIBE* = 35
  CMD_SET_SINK_VOLUME* = 36
  CMD_CORK_PLAYBACK_STREAM* = 41
  CMD_FLUSH_PLAYBACK_STREAM* = 42
  CMD_TRIGGER_PLAYBACK_STREAM* = 43
  CMD_GET_SINK_INPUT_INFO* = 29
  CMD_GET_SINK_INPUT_INFO_LIST* = 30
  CMD_REGISTER_MEMFD_SHMID* = 31
  CMD_REQUEST* = 61

  TAG_STRING* = 0x74
  TAG_STRING_NULL* = 0x4E
  TAG_U32* = 0x4C
  TAG_U8* = 0x42
  TAG_U64* = 0x52
  TAG_S64* = 0x72
  TAG_SAMPLE_SPEC* = 0x61
  TAG_ARBITRARY* = 0x78
  TAG_BOOLEAN_TRUE* = 0x31
  TAG_BOOLEAN_FALSE* = 0x30
  TAG_TIMEVAL* = 0x54
  TAG_USEC* = 0x55
  TAG_CHANNEL_MAP* = 0x6D
  TAG_CVOLUME* = 0x76
  TAG_PROPLIST* = 0x50
  TAG_VOLUME* = 0x56

  PA_SAMPLE_U8* = 0
  PA_SAMPLE_S16LE* = 3
  PA_INVALID_INDEX* = 0xFFFFFFFF'u32
  ERR_ACCESS* = 4
  ERR_NOENTITY* = 5
  ERR_NOTSUPPORTED* = 14
  ERR_NOTIMPLEMENTED* = 15

type
  TagWriter* = object
    buf*: seq[uint8]

  TagReader* = object
    buf: seq[uint8]
    pos: int

proc initWriter*(): TagWriter = TagWriter(buf: @[])
proc initReader*(data: openArray[uint8]): TagReader = TagReader(buf: @data, pos: 0)
proc len*(tw: TagWriter): int = tw.buf.len
proc eof*(tr: TagReader): bool = tr.pos >= tr.buf.len
proc writerData*(tw: TagWriter): seq[uint8] = tw.buf

# Raw byte helpers
proc w8(s: var seq[uint8]; v: uint8) = s.add v
proc w32(s: var seq[uint8]; v: uint32) =
  var tmp: array[4, uint8]
  bigEndian32(tmp[0].addr, v.addr)
  for b in tmp: s.add b
proc w64(s: var seq[uint8]; v: uint64) =
  var tmp: array[8, uint8]
  bigEndian64(tmp[0].addr, v.addr)
  for b in tmp: s.add b

proc r8(s: seq[uint8]; p: var int): uint8 =
  if p < s.len: result = s[p]; inc p
proc r32(s: seq[uint8]; p: var int): uint32 =
  if p + 4 <= s.len:
    var tmp: array[4, uint8]
    for i in 0..3: tmp[i] = s[p+i]
    inc p, 4
    bigEndian32(result.addr, tmp[0].addr)
proc r64(s: seq[uint8]; p: var int): uint64 =
  if p + 8 <= s.len:
    var tmp: array[8, uint8]
    for i in 0..7: tmp[i] = s[p+i]
    inc p, 8
    bigEndian64(result.addr, tmp[0].addr)

# Tagged put operations
proc putTag*(tw: var TagWriter; tag: uint8) = tw.buf.w8(tag)
proc putU32*(tw: var TagWriter; v: uint32) = tw.buf.w8(TAG_U32); tw.buf.w32(v)
proc putU8*(tw: var TagWriter; v: uint8) = tw.buf.w8(TAG_U8); tw.buf.w8(v)
proc putU64*(tw: var TagWriter; v: uint64) = tw.buf.w8(TAG_U64); tw.buf.w64(v)
proc putS64*(tw: var TagWriter; v: int64) = tw.buf.w8(TAG_S64); tw.buf.w64(cast[uint64](v))
proc putString*(tw: var TagWriter; s: string) =
  tw.buf.w8(TAG_STRING)
  for c in s: tw.buf.w8(c.uint8)
  tw.buf.w8(0)
proc putNullString*(tw: var TagWriter) = tw.buf.w8(TAG_STRING_NULL)
proc putBoolean*(tw: var TagWriter; v: bool) = tw.buf.w8(if v: uint8(TAG_BOOLEAN_TRUE) else: uint8(TAG_BOOLEAN_FALSE))
proc putArbitrary*(tw: var TagWriter; data: openArray[uint8]) =
  tw.buf.w8(TAG_ARBITRARY); tw.buf.w32(data.len.uint32)
  for b in data: tw.buf.w8(b)
proc putSampleSpec*(tw: var TagWriter; fmt, ch: uint8; rate: uint32) =
  tw.buf.w8(TAG_SAMPLE_SPEC); tw.buf.w8(fmt); tw.buf.w8(ch); tw.buf.w32(rate)
proc putChannelMap*(tw: var TagWriter; map: openArray[uint8]) =
  tw.buf.w8(TAG_CHANNEL_MAP); tw.buf.w8(map.len.uint8)
  for ch in map: tw.buf.w8(ch)
proc putCvolume*(tw: var TagWriter; channels: uint8; values: openArray[uint32]) =
  tw.buf.w8(TAG_CVOLUME); tw.buf.w8(channels)
  for i in 0 ..< int(channels): tw.buf.w32(if i < values.len: values[i] else: 0)
proc putProplist*(tw: var TagWriter; entries: openArray[tuple[k, v: string]]) =
  tw.buf.w8(TAG_PROPLIST)
  for (k, v) in entries:
    tw.putString(k); tw.buf.w32(v.len.uint32)
    for c in v: tw.buf.w8(c.uint8)
  tw.putNullString()
proc putTimeval*(tw: var TagWriter; sec, usec: uint32) =
  tw.buf.w8(TAG_TIMEVAL); tw.buf.w32(sec); tw.buf.w32(usec)
proc putUsec*(tw: var TagWriter; v: uint64) =
  tw.buf.w8(TAG_USEC); tw.buf.w64(v)
proc putVolume*(tw: var TagWriter; v: uint32) =
  tw.buf.w8(TAG_VOLUME); tw.buf.w32(v)

# Tagged get operations
proc getTag*(tr: var TagReader): uint8 = tr.buf.r8(tr.pos)
proc getU32*(tr: var TagReader): uint32 =
  if tr.getTag() != TAG_U32: return 0
  tr.buf.r32(tr.pos)
proc getU8Tag*(tr: var TagReader): uint8 =
  if tr.getTag() != TAG_U8: return 0
  tr.buf.r8(tr.pos)
proc getString*(tr: var TagReader): string =
  let t = tr.getTag()
  if t == TAG_STRING_NULL: return ""
  if t != TAG_STRING: return ""
  var n = 0
  while tr.pos + n < tr.buf.len and tr.buf[tr.pos + n] != 0:
    inc n
  result = newString(n)
  for i in 0 ..< n:
    result[i] = chr(tr.buf[tr.pos + i])
  tr.pos += n + 1  # skip NUL
proc getBoolean*(tr: var TagReader): bool =
  tr.getTag() == TAG_BOOLEAN_TRUE
proc getArbitrary*(tr: var TagReader; maxLen: int = -1): seq[uint8] =
  if tr.getTag() != TAG_ARBITRARY: return @[]
  let len = tr.buf.r32(tr.pos)
  let n = if maxLen >= 0 and len.int > maxLen: maxLen else: len.int
  result = newSeq[uint8](n)
  for i in 0 ..< n: result[i] = tr.buf.r8(tr.pos)
  tr.pos += int(len) - n
proc getSampleSpec*(tr: var TagReader): tuple[fmt, ch: uint8; rate: uint32] =
  if tr.getTag() != TAG_SAMPLE_SPEC: return (0, 0, 0)
  let fmt = tr.buf.r8(tr.pos)
  let ch = tr.buf.r8(tr.pos)
  let rate = tr.buf.r32(tr.pos)
  (fmt, ch, rate)
proc getChannelMap*(tr: var TagReader): seq[uint8] =
  if tr.getTag() != TAG_CHANNEL_MAP: return @[]
  let n = tr.buf.r8(tr.pos)
  result = newSeq[uint8](n)
  for i in 0 ..< int(n): result[i] = tr.buf.r8(tr.pos)
proc getTimeval*(tr: var TagReader): tuple[sec, usec: uint32] =
  if tr.getTag() != TAG_TIMEVAL: return (0, 0)
  (tr.buf.r32(tr.pos), tr.buf.r32(tr.pos))
proc getCvolume*(tr: var TagReader): seq[uint32] =
  if tr.getTag() != TAG_CVOLUME: return @[]
  let n = tr.buf.r8(tr.pos)
  result = newSeq[uint32](n)
  for i in 0 ..< int(n): result[i] = tr.buf.r32(tr.pos)

# Frame header (5 x BE uint32)
type FrameHdr* = object
  length*, channel*, offsetHi*, offsetLo*, flags*: uint32

proc readFrame*(data: openArray[uint8]): tuple[hdr: FrameHdr; payload: seq[uint8]] =
  var tr = initReader(data)
  let lenV = tr.buf.r32(tr.pos)
  let ch = tr.buf.r32(tr.pos)
  let oh = tr.buf.r32(tr.pos)
  let ol = tr.buf.r32(tr.pos)
  let fl = tr.buf.r32(tr.pos)
  let hdr = FrameHdr(length: lenV, channel: ch, offsetHi: oh, offsetLo: ol, flags: fl)
  let remaining = tr.buf.len - tr.pos
  let datalen = min(int(lenV), remaining)
  var payload = newSeq[uint8](datalen)
  for i in 0 ..< datalen:
    payload[i] = tr.buf.r8(tr.pos)
  (hdr, payload)

proc buildFrame*(channel, length: uint32; payload: openArray[uint8]; offsetHi = 0u32; offsetLo = 0u32; flags = 0u32): seq[uint8] =
  result = newSeq[uint8](20 + payload.len)
  var p = 0
  template putBE(v: uint32) =
    result[p] = ((v shr 24) and 0xFF).uint8
    result[p+1] = ((v shr 16) and 0xFF).uint8
    result[p+2] = ((v shr 8) and 0xFF).uint8
    result[p+3] = (v and 0xFF).uint8
    p += 4
  putBE(length)
  putBE(channel)
  putBE(offsetHi)
  putBE(offsetLo)
  putBE(flags)
  let plen = payload.len
  if p + plen > result.len:
    echo "SHOULD NOT HAPPEN: p=", p, " plen=", plen, " rlen=", result.len
    result.setLen(p + plen)
  for i in 0 ..< plen:
    result[p + i] = payload[i]

proc buildPacketFrame*(tw: var TagWriter): seq[uint8] =
  let payload = tw.buf
  tw.buf = @[]
  result = buildFrame(channel = 0xFFFFFFFF'u32, length = payload.len.uint32, payload)

proc paFrameSize*(format, channels: uint8): int =
  result = channels.int
  case format:
  of 0, 1, 2: result *= 1
  of 3, 4: result *= 2
  else: result *= 4
