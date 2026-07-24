# Setup

## 1. Create the Firebase project

Create a Firebase project on the Blaze plan and choose locations before creating data:

- Firestore: `eur3`
- Cloud Functions: `europe-west1`
- Vertex AI: `global` by default, or a regional endpoint supporting the configured Gemini model

Enable:

- Firebase Authentication
- Cloud Firestore
- Cloud Functions
- Vertex AI API

Cloud Storage, Cloud Tasks, and Speech-to-Text are not part of this architecture.

Copy `.firebaserc.example` to `.firebaserc` and replace the placeholder project ID.

## 2. Register the Apple apps

Register two Firebase Apple apps:

| Target | Bundle ID |
|---|---|
| iOS | `com.conor2405.noted` |
| macOS | `com.conor2405.noted.macos` |

Download each configuration file to:

```text
NotedApp/Configuration/iOS/GoogleService-Info.plist
NotedApp/Configuration/macOS/GoogleService-Info.plist
```

These files are ignored by Git. XcodeGen includes each file only in its matching platform target, and clean checkouts continue to support local-only transcription.

In Firebase Authentication, enable **Apple**. In the Apple Developer portal:

1. Enable Sign in with Apple for both identifiers.
2. Create the required Service ID and private key.
3. Add the Firebase authentication return URL.
4. Configure Firebase with the Team ID, Key ID, private key, and Service ID.

## 3. Generate and sign the Xcode project

Noted requires Xcode 26.2 or newer and targets iOS 26/macOS 26.

```bash
brew install xcodegen
make project
open Noted.xcodeproj
```

In Xcode:

1. Select the development team for both app targets.
2. Confirm the bundle identifiers.
3. Confirm Sign in with Apple.
4. Confirm microphone and background-audio capabilities.
5. Build and launch once in the foreground.
6. Grant microphone permission and let the current-language Apple speech model install.

The macOS target uses App Sandbox with audio input, outgoing network, user-selected read/write files, and app-scoped security bookmarks.

## 4. Configure and deploy the backend

Install dependencies:

```bash
npm --prefix functions ci
```

The backend reads deploy-time values for the Google Cloud project, Functions region, Vertex AI location, and Gemini model. Apple Speech has no backend key, recognizer, API enablement, or per-minute billing.

Build and test:

```bash
npm --prefix functions run lint
npm --prefix functions test
npm --prefix functions run build
```

Deploy:

```bash
firebase deploy --only firestore:rules,firestore:indexes,functions
```

## 5. App Check

App Check enforcement is production hardening and is not enabled in this MVP. Before enforcement, add Firebase App Check to the Apple target, use a debug provider locally and App Attest or DeviceCheck in production, review metrics, then enforce it for Firestore, Authentication, and backend resources.

## 6. Test the complete path

1. Launch Noted and grant microphone permission.
2. Confirm the Apple speech-model preparation completes.
3. Record and stop a short conversation while signed out.
4. Verify the state moves to **Transcribing on device** and a timestamped local transcript appears.
5. Confirm no audio object or Storage request is made.
6. Sign in with Apple and verify **Syncing transcript → Creating note → Ready**.
7. Confirm the note and transcript appear on a second signed-in Apple device.
8. Select an iCloud Drive or Obsidian folder and confirm automatic Markdown export.
9. Configure the Action Button and repeat while the iPhone is locked.
10. Test offline capture, a long transcription interrupted by suspension, sign-in after capture, revoked folder access, and app relaunch.

## Known MVP limits

- iOS 26/macOS 26 minimum.
- No live transcription.
- No system or third-party phone-call capture.
- No speaker identification or diarisation.
- Timestamps are finalized-result ranges, not exact word offsets.
- Locale and device support depend on Apple’s installed speech assets.
- Long post-recording transcription can resume only when iOS next runs the app.
- Local folder export is eventually automatic but cannot run while iOS withholds execution after force-quit.
