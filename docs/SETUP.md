# Setup

## 1. Create the Firebase project

Create a Firebase project on the Blaze plan and choose its locations before creating data:

- Firestore: `eur3`
- Cloud Storage: a compatible European location
- Cloud Functions: `europe-west1`
- Speech-to-Text recognizer: `eu`
- Vertex AI: `global` by default, or a regional endpoint that supports the configured Gemini model

Enable:

- Firebase Authentication
- Cloud Firestore
- Cloud Storage
- Cloud Functions
- Cloud Tasks
- Speech-to-Text API
- Vertex AI API

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

These files are ignored by Git.

Run `make project` after adding or replacing either file. XcodeGen scans each
platform configuration directory for that file and includes it only for its
matching destination, so the iOS and macOS files can share the required
`GoogleService-Info.plist` bundle name without colliding. Clean checkouts and CI
omit both files and continue to use Noted's demo fallback.

In Firebase Authentication, enable **Apple**. In the Apple Developer portal:

1. Enable Sign in with Apple for both identifiers.
2. Create the required Service ID and private key.
3. Add the Firebase authentication return URL.
4. Configure Firebase with the Team ID, Key ID, private key, and Service ID.

## 3. Generate and sign the Xcode project

Noted requires Xcode 26.2 or newer.

```bash
brew install xcodegen
make project
open Noted.xcodeproj
```

In Xcode:

1. Select the development team for both app targets.
2. Confirm the bundle identifiers.
3. Confirm the Sign in with Apple capability.
4. Confirm microphone and background audio capabilities.
5. Build and run once in the foreground before testing the Action Button.

The macOS target uses App Sandbox with audio input, outgoing network, user-selected read/write files, and app-scoped security bookmarks.

## 4. Configure backend parameters

Install dependencies:

```bash
npm --prefix functions ci
```

The backend reads deploy-time configuration for:

- Google Cloud project ID
- Speech location, model, and default locale
- Vertex AI location and Gemini model
- maximum accepted recording size

Defaults are set for `eu`, `chirp_3`, `en-GB`, and the repository's current stable Gemini Flash choice. Model names remain server-configurable so an app release is not required to change them.

Build and test:

```bash
npm --prefix functions run lint
npm --prefix functions test
npm --prefix functions run build
```

Deploy:

```bash
firebase deploy --only firestore:rules,firestore:indexes,storage,functions
```

After deployment, apply a Cloud Storage lifecycle rule that deletes abandoned temporary recordings after the agreed retention window.

## 5. App Check

App Check enforcement is production hardening and is not enabled in this MVP. Before enforcement, add the Firebase App Check package product, configure a debug provider for local builds and App Attest or DeviceCheck where supported for production, then review metrics before enforcing it for Firestore, Storage, Authentication, and backend resources.

## 6. Test the complete path

1. Sign in with Apple.
2. Grant microphone permission.
3. Record a short conversation in Noted.
4. Stop and verify the states move through Uploading, Transcribing, Creating notes, and Ready.
5. Confirm the note and transcript are visible on both Apple devices.
6. Pick an iCloud Drive or Obsidian folder and enable automatic export.
7. Record again and confirm a deterministic Markdown file appears without pressing an export button.
8. Configure the Action Button shortcut and repeat while the phone is locked.
9. Test offline recording, interrupted upload, revoked folder access, duplicate backend delivery, and app relaunch.

## Known MVP limits

- No live transcription.
- No system or third-party phone-call capture.
- Exact word-level timestamps are not guaranteed.
- Speaker identities are labels rather than named people.
- Local folder export is eventually automatic but cannot run while iOS withholds execution after a force-quit.
- Recordings longer than the configured Speech-to-Text batch envelope need client or backend segmentation.
