# Murmur

Push-to-talk dictation for macOS. Hold a key, speak, release. The transcript lands
where your cursor is. Everything runs on this Mac; the audio is deleted the moment
it has been transcribed and never leaves the machine.

## Keys

| | |
|---|---|
| **Hold ⌃⌥/** | Record while held, release to transcribe |
| **Double-tap ⌃⌥/** | Lock recording on, so you can stop holding. Any key stops it |
| **⌃⌥.** | Cycle the primary language |
| **Esc** | Cancel the recording and throw the audio away |

## Language

whisper settles on one language per clip, so naming the dominant one beats leaving it
to guess. Three modes cycle with ⌃⌥. :

- **English, with Arabic mixed in** — the default
- **Arabic, with English mixed in** — Egyptian and MSA are both covered
- **Detect automatically**

## Where the transcript goes

If whatever has keyboard focus accepts text, it is pasted there. If not, it is left on
the clipboard and the overlay says so. Either way the clipboard holds it, so a failed
paste is still a ⌘V away.

## Build

Needs only the Command Line Tools. No Xcode project, no dependencies.

```bash
./build.sh
cp -R build/Murmur.app /Applications/
```

Requires `whisper-cli` on the path (`brew install whisper-cpp`) and the model at
`~/.local/share/whisper-models/ggml-large-v3-turbo.bin`.

## Permissions

- **Microphone** — to record.
- **Accessibility** — to notice the hotkey and to paste. The app checks on launch and
  walks you to the right settings pane if it is missing.

Rebuilding the binary can invalidate the Accessibility grant, since the app is ad-hoc
signed. If the hotkey stops working after a rebuild, remove Murmur from the
Accessibility list and add it again.

## Safety rails

Two-minute cap on a single recording. Clips under 0.4s are discarded as mis-presses.
Silent clips are rejected before whisper is invoked. Transcription is killed after 90
seconds. The event tap is re-armed every five seconds, because macOS disables taps that
ever block and the app would otherwise go quietly deaf.
