# Noted

Noted is a native iPhone and Mac capture app for turning in-person conversations into useful notes in the systems people already use.

The MVP records from the app or an iPhone Action Button shortcut, transcribes the local recording with Apple Speech, syncs only the timestamped text through Firebase, and creates a structured note with Gemini. Notes and transcripts remain visible in Noted and can be written automatically into a selected folder such as an Obsidian vault.

## MVP capabilities

- Native SwiftUI apps for iOS 26+ and macOS 26+
- In-app M4A recording with device-local audio retention
- `AudioRecordingIntent` and App Shortcut for the iPhone Action Button
- Apple `SpeechAnalyzer` and `SpeechTranscriber` transcription, entirely on device
- Result-level transcript timestamps
- Sign in with Apple backed by Firebase Authentication
- Firestore-backed cross-device notes and transcripts with offline caching
- Gemini-generated notes using global and per-recording instructions
- Automatic Markdown export into a persistent user-selected folder
- Durable, idempotent transcription, sync, and export queues
- Local transcription when Firebase configuration or sign-in is absent

Apple Speech does not expose speaker diarisation, so the MVP does not show or promise speaker identification. Phone, FaceTime, and third-party call recording are also outside this MVP.

## Repository layout

```text
NotedApp/                 SwiftUI application and tests
functions/                Firebase Functions TypeScript backend
docs/                     Architecture and setup documentation
project.yml               XcodeGen project definition
firebase.json             Firebase emulator and deployment configuration
firestore.rules           Firestore access rules
```

## Quick start

### Apple app

Requirements:

- macOS with Xcode 26.2 or newer
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- An Apple Developer team for device testing of Sign in with Apple and App Intents

```bash
brew install xcodegen
make project
open Noted.xcodeproj
```

On first launch, grant microphone access and leave the app open while Apple installs the current-language speech model. The model lives in system storage, updates through Apple, and has no per-minute API charge.

Without Firebase configuration, Noted records and transcribes locally. Add Firebase to sync the transcript and create Gemini notes; follow [the setup guide](docs/SETUP.md).

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

Only Gemini note generation requires a deployed Google Cloud model service. Audio is never uploaded.

## Action Button setup

1. Launch Noted once, grant microphone permission, and let the speech model install.
2. Open **Settings → Action Button → Shortcut** on the iPhone.
3. Select **Noted → Toggle Recording**.
4. Hold the Action Button once to start and again to stop.

Recording and transcription work without signing in. Sign in is required to sync a transcript and generate a Gemini note. If iOS ends background execution before a long file finishes, Noted’s durable queue resumes automatically the next time the app runs.

## Automatic folder export

In Noted settings, enable automatic export and choose a writable folder. Noted stores a device-local security-scoped bookmark and writes one deterministic Markdown file per completed recording.

iOS controls background execution. Export normally happens as soon as processing finishes, but after suspension or force-quit the durable queue catches up the next time Noted receives execution.

## Integration boundary

The MVP’s automatic Markdown-folder integration covers Obsidian, iCloud Drive, and other file-based workflows. Firestore export rules and attempts provide the boundary for direct Notion, ChatGPT, and future destinations; provider authentication and delivery workers remain follow-up integrations.

## Development status

This is an MVP foundation. Before App Store distribution it still needs a configured Firebase project, Apple signing, physical-device Action Button and speech-model testing, production privacy copy, and evaluation against representative meeting audio.
