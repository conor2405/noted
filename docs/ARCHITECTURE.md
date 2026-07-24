# Architecture

## Ownership

Firebase is the cross-device source of truth for text artifacts. Audio and device capabilities remain native.

| Data | Owner |
|---|---|
| Original M4A recording | Capturing device |
| Apple speech model | Apple-managed system storage |
| Pending transcription and sync work | Capturing device |
| Timestamped transcript chunks | Cloud Firestore after local transcription |
| Generated note and processing state | Cloud Firestore |
| User note preferences | Cloud Firestore |
| Pending folder exports | Exporting device |
| Folder security-scoped bookmark | Authorising device |

CloudKit is deliberately not used. Firebase already owns identity, note generation, and synced artifacts; adding CloudKit would introduce a second conflict and reconciliation system.

## Processing flow

```text
AVAudioRecorder
    ↓ local M4A + durable work item
Apple SpeechAnalyzer / SpeechTranscriber
    ↓ timestamped text, on device
Cloud Firestore
    ↓ completed-transcript event
Gemini Flash + captured note preferences
    ↓ structured Markdown note
Cloud Firestore
    ├── listeners → Noted Note and Transcript views
    └── export attempt → device folder queue → selected folder
```

When Firebase is unavailable or the user is signed out, local transcription still completes. The queued transcript sync resumes after sign-in. No audio object, audio URL, or cloud audio retention path exists.

## Client boundaries

- `AudioRecorder`: microphone permission and AVFoundation recording.
- `OnDeviceTranscriptionService`: locale resolution, Apple model installation, file analysis, and timestamp extraction.
- `FirebaseCloudRepository`: transcript-chunk sync, Firestore listeners, preferences, and export receipts.
- `AppModel`: durable recording/transcription/sync orchestration.
- `FolderExportService`: security-scoped folder access, Markdown rendering, atomic writes, and retries.

Firestore offline persistence is the synced-data cache. Device-local operational state is stored separately and is never treated as another cross-device database.

## Firestore shape

```text
users/{uid}
  preferences/default
  recordings/{recordingId}
    transcriptChunks/{sequence}
  exportRules/{ruleId}
  exportAttempts/{attemptId}

noteRegenerationJobs/{eventHash}   # server-only generation lease
```

Recording documents include `syncState`, `transcriptionState`, `noteState`, and `exportState`. Transcript content is chunked to stay below Firestore’s document-size limit.

The client creates an in-progress recording document, writes deterministic sequence-keyed chunks in bounded batches, then marks transcription and sync complete. The final update is the backend note-generation trigger. Firestore rules permit chunk writes only while the owning recording is in that in-progress state.

## Idempotency

Local work items are keyed by recording ID. Transcript documents are keyed by sequence, and a stable transcript version ties the recording, chunks, and generated note together. A retry overwrites the same logical artifacts.

Note generation uses a hash of the Firestore event ID as its lease/job ID. Folder-export receipts key by destination and recording, hash rendered content, and use deterministic filenames with atomic replacement.

## Timestamp and speaker policy

`SpeechTranscriber` returns finalized result ranges through the `audioTimeRange` attribute. Noted stores those ranges as result-level timestamps; it does not promise word-level timing.

Apple Speech does not expose speaker diarisation. `speakerLabel` remains an empty compatibility field in the transcript schema, is omitted in the UI and prompt text, and must not be presented as speaker identification.

## Model preparation and background behaviour

`SpeechTranscriber` is available from iOS 26 and macOS 26. The app resolves the current locale to a supported locale and asks `AssetInventory` to install its model during foreground onboarding. The model is Apple-managed and runs entirely on device.

Recording uses the audio background mode. Post-recording transcription receives only the background execution time iOS grants; a long file may pause when the process is suspended. The durable work item resumes on the next activation. Locked Action Button use therefore requires one prior foreground launch for microphone permission and speech-model preparation.

A selected folder can be written only by an authorised Apple device. Immediate folder delivery is not guaranteed after force-quit, but the queue catches up automatically.

## Security

- Sign in with Apple establishes a Firebase user ID.
- Audio never leaves the capturing device.
- Firestore rules limit metadata and transcript writes to the authenticated owner.
- Transcript chunks can be written only during the client’s bounded sync state.
- Generated artifacts are readable only by their owner.
- Folder bookmarks remain local to the device that received user consent.
- Gemini credentials are available only to the Functions service account.
- App Check should be observed in development and enforced before production.
