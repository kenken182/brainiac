# Mindflow

A macOS memory companion for your personal knowledge graph (gbrain). Hold
⌃⌥, speak about whatever's on screen, and a memory agent picks it up —
screenshot in hand, with gbrain and web search as tools.

## How it works

1. Hold ⌃⌥. The popup pill appears in the top right and starts recording.
2. Speak. Release to send. Follow-up turns toggle with single taps.
3. Mindflow transcribes the audio, snapshots the frontmost window, and hands
   both to the agent along with the app name and active URL (Chrome only).
4. The agent replies in a chat that takes over the popup. It can search your
   gbrain, write new pages, or pull in web context — whatever the moment
   calls for.
5. Close the chat with ⌥⎋ or ×. The session is logged locally; anything the
   agent saved to gbrain along the way stays there.

## Requirements

- macOS 14+ (developed on 26.x)
- Xcode 16+
- Node 20+ — the Claude Agent SDK runs in a bundled Node process
- `gbrain` CLI on `PATH`
- Anthropic API key
- Deepgram API key

## Setup

```sh
git clone https://github.com/kenken182/brainiac.git
cd brainiac
(cd AgentRuntime && npm install)
open Mindflow.xcodeproj
```

In Xcode:

1. **Edit Scheme → Run → Environment Variables** — add `ANTHROPIC_API_KEY`
   and `DEEPGRAM_API_KEY`. The scheme file is gitignored so your keys stay
   local.
2. **Signing & Capabilities** — pick a team (Personal Team is fine).
3. Run.

First launch prompts for Microphone, Screen Recording, and Input Monitoring.
The global hotkey won't fire until Input Monitoring is granted — open System
Settings → Privacy & Security → Input Monitoring and add the built `.app`
manually if you don't get a prompt.

## Hotkeys

| Gesture | What it does |
|---|---|
| ⌃⌥ (hold) | First turn — push-to-talk |
| ⌃⌥ (tap, then tap again) | Follow-up turn — tap to start, tap to send |
| ⌥⎋ | Close the chat |
| × in header | Close the chat |

## Project layout

```
Mindflow.xcodeproj/           Xcode project
Mindflow/                     Swift sources
  AppCore.swift                 top-level wiring
  HotkeyMonitor.swift           global ⌃⌥ listener
  AudioRecorder.swift           AVAudioRecorder → .wav
  ScreenCapturer.swift          ScreenCaptureKit → PNG
  DeepgramClient.swift          transcription
  ChatAgent.swift               conversation state + agent loop
  ChatView.swift                chat surface
  PopupController.swift         floating NSPanel
  MindflowAgentBridge.swift     spawns the Node bridge
  MemoryStore.swift             per-session JSONL log
  Resources/AgentBridge/
    bridge.mjs                  Claude Agent SDK runner
AgentRuntime/
  package.json                  Agent SDK + deps
  skills/                       SKILL.md files the agent reads on demand
    voice-note-ingest/
    media-ingest/
    brain-ops/
    query/
```

## Status

Hackathon project. UX is opinionated and rough around the edges.
