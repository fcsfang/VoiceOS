#!/usr/bin/env python3
import struct
import sys
import wave
from pathlib import Path

out = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/voiceos-fixture.wav")
seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 1.0
out.parent.mkdir(parents=True, exist_ok=True)
frames = int(44100 * seconds)
with wave.open(str(out), "wb") as w:
    w.setnchannels(1)
    w.setsampwidth(2)
    w.setframerate(44100)
    w.writeframes(struct.pack("<h", 0) * frames)
print(out)
