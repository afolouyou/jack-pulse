import jacket, strformat
import ringbuffer

const MaxAudioChannels = 8

type
  StreamInfo* = object
    id*: uint32
    sampleFmt*: uint8
    sampleChannels*: uint8
    sampleRate*: uint32
    ports*: seq[Port]
    ring*: ptr AudioRing
    volume*: float32
    active*: bool

  JackState* = object
    client*: Client
    running*: bool
    bufferSize*: NFrames
    sampleRate*: NFrames
    streams*: seq[StreamInfo]

var jack*: JackState

proc jackProcessCb(nframes: NFrames; arg: pointer): cint {.cdecl.} =
  for st in mitems(jack.streams):
    if not st.active or st.ports.len == 0 or st.ring == nil:
      continue
    var buf: array[MaxAudioChannels, ptr UncheckedArray[DefaultAudioSample]]
    let nch = min(st.ports.len, MaxAudioChannels)
    for ch in 0 ..< nch:
      if st.ports[ch] != nil:
        buf[ch] = cast[ptr UncheckedArray[DefaultAudioSample]](
          portGetBuffer(st.ports[ch], nframes))
    var tmp: array[4096, float32]
    let nf = min(nframes, NFrames(4096))
    let n = ringRead(st.ring, tmp[0].addr, nf)
    for ch in 0 ..< nch:
      if buf[ch] == nil:
        continue
      for i in 0 ..< int(nf):
        if i < int(n):
          buf[ch][i] = tmp[i]
        else:
          buf[ch][i] = 0.0
  return 0

proc jackShutdownCb(arg: pointer) {.cdecl.} =
  jack.running = false

proc connectJack*(clientName: string): bool =
  var status: cint
  let c = clientOpen(clientName, NullOption, status.addr)
  if c == nil:
    return false
  jack.client = c
  jack.sampleRate = getSampleRate(c)
  jack.bufferSize = getBufferSize(c)
  onShutdown(c, jackShutdownCb, nil)
  discard setProcessCallback(c, jackProcessCb, nil)
  if activate(c) != 0:
    return false
  jack.running = true
  true

proc disconnectJack*() =
  if jack.client != nil:
    discard deactivate(jack.client)
    discard clientClose(jack.client)
    jack.client = nil
  jack.running = false

proc jackAddStream*(streamId: uint32; channels: uint8): bool =
  var st: StreamInfo
  st.id = streamId
  st.active = true
  if channels > 0:
    let nch = min(channels.int, MaxAudioChannels)
    for ch in 0 ..< nch:
      let suffix = chr(ord('1') + ch)
      let portName = cstring(fmt"jack-pulse_{streamId}_out_{suffix}")
      let port = portRegister(jack.client, portName, JackDefaultAudioType, culong(PortIsOutput), 0)
      if port != nil:
        st.ports.add(port)
    st.ring = cast[ptr AudioRing](alloc0(sizeof(AudioRing)))
    if st.ring != nil:
      initRing(st.ring, RingSizeFrames.uint32)
    let sysPorts = getPorts(jack.client, "system:playback_?", JackDefaultAudioType, culong(PortIsInput))
    if sysPorts != nil:
      for ch in 0 ..< min(nch, st.ports.len):
        if ch < st.ports.len:
          let outName = cstring($portName(st.ports[ch]))
          let sysName = cstring($sysPorts[ch])
          discard connect(jack.client, outName, sysName)
      free(sysPorts)
  jack.streams.add(st)
  true

proc jackRemoveStream*(streamId: uint32) =
  for i in 0 ..< jack.streams.len:
    if jack.streams[i].id == streamId:
      let st = addr jack.streams[i]
      st.active = false
      for p in st.ports:
        if p != nil:
          discard portDisconnect(jack.client, p)
      st.ports.setLen(0)
      if st.ring != nil:
        destroyRing(st.ring)
        dealloc(st.ring)
        st.ring = nil
      jack.streams.delete(i)
      break

proc jackWriteAudio*(streamId: uint32; data: ptr float32; frames: uint32) =
  for st in mitems(jack.streams):
    if st.id == streamId and st.ring != nil:
      discard ringWrite(st.ring, data, frames)
      break

proc jackStreamAvail*(streamId: uint32): uint32 =
  for st in mitems(jack.streams):
    if st.id == streamId and st.ring != nil:
      return ringAvail(st.ring)
  return 0
