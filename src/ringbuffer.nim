import std/atomics

const RingSizeFrames* = 4096

type AudioRing* = object
  buf: ptr UncheckedArray[float32]
  size: uint32
  writeIdx*: Atomic[uint32]
  readIdx*: Atomic[uint32]

proc initRing*(rb: ptr AudioRing; sizeFrames: uint32) =
  var sz = sizeFrames
  if (sz and (sz - 1)) != 0:
    sz = 1
    while sz < sizeFrames: sz = sz shl 1
  rb.size = sz
  rb.buf = cast[ptr UncheckedArray[float32]](alloc0(sz.int * sizeof(float32)))
  store(rb.writeIdx, 0u32)
  store(rb.readIdx, 0u32)

proc destroyRing*(rb: ptr AudioRing) =
  if rb.buf != nil:
    dealloc(rb.buf)
    rb.buf = nil

proc ringFree*(rb: ptr AudioRing): uint32 =
  let w = load(rb.writeIdx)
  let r = load(rb.readIdx)
  rb.size - (w - r) - 1

proc ringAvail*(rb: ptr AudioRing): uint32 =
  load(rb.writeIdx) - load(rb.readIdx)

proc ringWrite*(rb: ptr AudioRing; data: ptr float32; frames: uint32): uint32 =
  let mask = rb.size - 1
  let arr = cast[ptr UncheckedArray[float32]](data)
  for i in 0 ..< frames.int:
    let w = load(rb.writeIdx)
    let r = load(rb.readIdx)
    if w - r >= rb.size:
      return i.uint32
    rb.buf[w and mask] = arr[i]
    store(rb.writeIdx, w + 1)
  return frames

proc ringRead*(rb: ptr AudioRing; buf: ptr float32; frames: uint32): uint32 =
  let mask = rb.size - 1
  let arr = cast[ptr UncheckedArray[float32]](buf)
  for i in 0 ..< frames.int:
    let r = load(rb.readIdx)
    let w = load(rb.writeIdx)
    if r >= w:
      return i.uint32
    arr[i] = rb.buf[r and mask]
    store(rb.readIdx, r + 1)
  return frames

proc ringClear*(rb: ptr AudioRing) =
  store(rb.readIdx, load(rb.writeIdx))
