# Noted

Noted is a native iPhone and Mac capture app for turning in-person conversations into useful notes in the systems people already use.

The MVP records from the app or an iPhone Action Button shortcut, uploads a temporary processing copy, transcribes it with Google Cloud Speech-to-Text, creates a structured note with Gemini, and makes both the note and timestamped transcript available in Noted. A device can automatically write the result into a user-selected folder such as an Obsidian vault.

## MVP capabilities

- Native SwiftUI apps for iOS 18+ and macOS 15+
- In-app M4A recording with local audio retention
- `AudioRecordingIntent` and App Shortcut for the iPhone Action Button
- Sign in with Apple backed by Firebase Authentication
- Firestore-backed cross-device notes and transcripts with offline caching
- Google Speech-to-Text V2 `chirp_3` batch transcription
- Speaker-labelled, paragraph-level transcript timestamps
- Gemini-generated structured notes using a global preference and optional per-recording override
- Automatic Markdown export into a persistent user-selected folder
- Durable, idempotent upload and export queues
- Local demo mode when Firebase configuration is absent

Phone, FaceTime, and third-party call recording are intentionally outside this MVP.

## Repository layout

```text
NotedApp/                 SwiftUI application and tests
functions/                Firebase Functions TypeScript backend
docs/                     Architecture and setup documentation
project.yml               XcodeGen project definition
firebase.json             Firebase emulator and deployment configuration
firestore.rules           Firestore access rules
storage.rules             Temporary recording upload rules
```

## Quick start

### Apple app

Requirements:

- macOS with Xcode
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- An Apple Developer team for device testing of Sign in with Apple and App Intents

```bash
brew install xcodegen
make project
open Noted.xcodeproj
```

Without Firebase configuration, Noted launches in local demo mode so the recording and interface flows can be exercised. For a working cloud pipeline, follow [the setup guide](docs/SETUP.md).

### Backend

Requirements:

- Node.js 22
- Firebase CLI
- A Firebase project on the Blaze plan

```bash
npm --prefix functions ci
npm --prefix functions test
npm --prefix functions run build
firebase emulators:start
```

Speech-to-Text and Gemini calls require deployed Google Cloud services; the pure transformation and state-machine code is covered by local tests.

## Action Button setup

1. Launch Noted once, sign in, and grant microphone permission.
2. Open **Settings → Action Button → Shortcut** on the iPhone.
3. Select **Noted → Toggle Recording**.
4. Hold the Action Button once to start and again to stop.

The original audio remains on the recording device. Notes and transcripts sync through Firestore.

## Automatic folder export

In Noted settings, enable automatic export and choose a writable folder. Noted stores a device-local security-scoped bookmark and writes one deterministic Markdown file per completed recording.

iOS controls background execution. Export normally happens as soon as processing finishes, but if Noted is suspended or force-quit, the durable queue completes the export the next time the app receives execution. No manual export action is required.

## Development status

This is an MVP foundation. Before App Store distribution it still needs a configured Firebase project, Apple signing, physical-device Action Button validation, production privacy copy, and end-to-end testing against real meeting audio.

