version     = "0.1.0"
author      = "folou"
description = "jack-pulse - PulseAudio over JACK (native PA protocol)"
license     = "MIT"
srcDir      = "src"

requires "nim >= 1.6.0"
requires "jacket"

bin = @["jackpulse"]

task test, "Build and run":
  exec "nim c -r src/jackpulse"
