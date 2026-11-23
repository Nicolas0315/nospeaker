# trackpad-sounds

Play with the MacBook trackpad's haptic motor from a web page.

Browsers can't drive the motor, so a small local helper does it: the page talks to the helper over a
same-origin WebSocket, and the helper plays the tones through MultitouchSupport (the same private-framework
approach as [nospeaker.swift](../nospeaker.swift)).

```sh
cd trackpad-sounds
./build.sh
./trackpad-sounds --open        # http://localhost:8765 (--port N to change)
```

Modes: theremin, piano, hot & cold (blind search by pitch and rhythm), morse, a frequency lab, and beat sync
(detects kick and hi-hat from a file, a shared tab's audio, the mic or a built-in demo beat, and taps the
trackpad on each hit).
Without the helper (or without a haptic motor) the page falls back to browser audio.

Safety: the helper listens on loopback only, checks the Host and Origin headers so other websites can't drive it,
and falls silent if the page stops sending for 1.5 s. Like nospeaker, it never exceeds the motor's normal strength.
MultitouchSupport is private, so a macOS update could break it.
