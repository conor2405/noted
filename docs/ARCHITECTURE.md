# Architecture

## Ownership

Noted uses Firebase as the cross-device source of truth and native storage only for device-specific state.

| Data | Owner |
|---|---|
| Recording metadata and processing state | Cloud Firestore |
| Generated note | Cloud Firestore |
| Timestamped transcript chunks | Cloud Firestore subcollection |
| User note preferences | Cloud Firestore |
| Original M4A recording | Capturing device |
| Temporary processing audio | Cloud Storage |
| Pending uploads and folder exports | Capturing/exporting device |
| Folder security-scoped bookmark | Authorising device |

CloudKit is deliberately not used. The Google processing backend already writes Firestore, and mirroring the same records into CloudKit would introduce a second identity, conflict model, and sync engine.

## Processing flow

```text
AVAudioRecorder
    ↓ local M4A + pending manifest
Firebase Storage
    ↓ object-finalized event
idempotent Firebase task
    ↓
Speech-to-Text V2 / chirp_3 / EU / en-GB
    ↓ transcript chunks
Cloud Firestore
    ↓
Gemini Flash + captured note preferences
    ↓ structured Markdown note
Cloud Firestore
    ├── Firestore listeners → Noted Note and Transcript views
    └── export attempt → device AutoExportQueue → selected folder
```

The cloud copy of the audio is deleted only after the transcript and generated note are durably written. A lifecycle policy should also remove abandoned uploads.

## Client model

The Apple targets share Swift source and use conditional compilation only for platform APIs such as `AVAudioSession` and macOS sandbox bookmark options.

The client has four main boundaries:

- `AudioRecorder`: microphone permission and AVFoundation recording.
- `FirebaseCloudRepository`: Firestore listeners, Storage uploads, preferences, and export receipts.
- `AppModel`: presentation state and orchestration between recording, repository updates, and exports.
- `FolderExportService`: security-scoped folder access, Markdown rendering, atomic coordinated writes, and idempotent retry state.

Firestore offline persistence is the synced-data cache. Device-local operational state is stored separately and never treated as another cross-device database.

## Firestore shape

```text
users/{uid}
  preferences/default
  recordings/{recordingId}
    transcriptChunks/{chunkId}
  exportRules/{ruleId}
  exportAttempts/{attemptId}

processingJobs/{jobHash}           # server-only
noteRegenerationJobs/{eventHash}   # server-only
```

The recording document contains small list/detail fields including `noteTitle`, `noteMarkdown`, and the independent stage states:

- `uploadState`
- `transcriptionState`
- `noteState`
- `exportState`

Transcript content is chunked because Firestore documents have a 1 MiB limit. The UI can show the transcript as soon as transcription succeeds while note generation or export continues.

## Idempotency

Storage and Firestore events may be delivered more than once. Every backend stage uses a stable key derived from the user ID, recording ID, Storage generation, stage, and artifact version. A retry may continue or replace the same artifact, but it must not create a second logical note or export.

Folder exports key receipts by destination and recording, and hash the rendered content plus relevant destination settings. A deterministic filename and atomic replacement make retries safe.

## Integration boundary

Transcription and note generation always end in the same Firestore artifact. Destination-specific delivery starts after that boundary. The MVP registers device-folder export rules for Obsidian and other file-based workflows; the same `exportRules` and `exportAttempts` shape is reserved for direct Notion, ChatGPT, and future integrations without making any of them part of the core processing stack.

## Timestamp policy

Chirp 3 batch recognition supports speaker diarisation but does not promise exact word-level timestamps. Noted stores speaker-labelled paragraph/result segments with start and end offsets. The UI and exports describe these as segment timestamps.

## Background behaviour

Recording uses the audio background mode. Processing continues on Google infrastructure after upload.

A local folder can only be written by the authorised Apple device. The backend creates or updates the ready artifact; the client attempts the write while foregrounded, during granted background execution, and on each later activation. Immediate delivery is not guaranteed after the user force-quits the iOS app.

## Security

- Sign in with Apple establishes a Firebase user ID.
- Firestore and Storage rules restrict paths to that user ID.
- App Check should be observed in development and enforced before production.
- Raw audio is not stored in Firestore.
- Generated artifacts are readable only by their owner.
- Folder bookmarks remain local to the device that received user consent.
- Backend model and Speech credentials are available only to service accounts.
