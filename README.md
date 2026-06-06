# jack-pulse

A PulseAudio protocol server over JACK audio backend. Translates PA client commands
into JACK audio operations, allowing PA-only applications to use a JACK daemon.

## Status

- `pactl info` - works, returns server metadata
- `pactl stat` - works, returns memory statistics
- Audio streaming - not yet implemented
- Volume/device control - not yet implemented

## Build

Requires Nim, JACK development headers, and a running JACK daemon.

```
nim c -d:release src/jackpulse.nim
```

## Usage

```sh
# Start JACK first
jackd -d dummy -r 48000 -p 1024 &

# Start jack-pulse
./src/jackpulse

# Connect via PA clients
PULSE_SERVER=unix:/tmp/pulse-1000/native pactl info
PULSE_SERVER=unix:/tmp/pulse-1000/native pactl stat
```

## Test

```sh
nim c -d:test -d:release tests/test_server.nim && ./tests/test_server
```
