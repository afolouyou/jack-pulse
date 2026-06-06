import std/[logging, strformat]
import server, jack_client

when isMainModule:
  addHandler(newConsoleLogger(fmtStr = "$datetime [$levelid] "))

  info "jack-pulse starting..."

  if not connectJack("jack-pulse"):
    error "Failed to connect to JACK server"
    quit(1)

  info fmt"Connected to JACK (rate={jack.sampleRate} buf={jack.bufferSize})"

  try:
    run()
  except:
    error "Fatal error: " & getCurrentExceptionMsg()
  finally:
    shutdown()
