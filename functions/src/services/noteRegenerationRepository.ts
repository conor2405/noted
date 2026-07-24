import { createHash } from "node:crypto";

import {
  FieldValue,
  Timestamp,
  getFirestore,
  type Firestore,
} from "firebase-admin/firestore";

import {
  RetryablePipelineError,
  TerminalPipelineError,
  safeClientError,
  type ClassifiedError,
} from "../domain/errors.js";
import { formatTimestamp } from "../domain/transcript.js";
import type {
  ExportRule,
  GeneratedNote,
  NotePreferencesSnapshot,
  Transcript,
  TranscriptSegment,
} from "../domain/types.js";

const MAX_REGENERATION_ATTEMPTS = 5;
const MAX_AUTOMATIC_EXPORT_RULES = 50;

export interface NoteRegenerationJob {
  id: string;
  uid: string;
  recordingId: string;
  transcriptVersion: string;
  preferences: NotePreferencesSnapshot;
  attemptCount: number;
}

export interface AcquireRegenerationResult {
  kind: "acquired" | "complete" | "terminal";
  job?: NoteRegenerationJob;
}

function regenerationJobId(eventId: string): string {
  return createHash("sha256").update(eventId).digest("hex");
}

function instructions(value: unknown): string {
  return typeof value === "string" ? value.slice(0, 20_000) : "";
}

export class NoteRegenerationRepository {
  public constructor(
    private readonly database: Firestore = getFirestore(),
  ) {}

  public async acquire(
    eventId: string,
    uid: string,
    recordingId: string,
    nowMilliseconds: number,
  ): Promise<AcquireRegenerationResult> {
    const id = regenerationJobId(eventId);
    const jobRef = this.database.collection("noteRegenerationJobs").doc(id);
    const userRef = this.database.collection("users").doc(uid);
    const recordingRef = userRef.collection("recordings").doc(recordingId);
    const preferenceRef = userRef.collection("preferences").doc("default");
    let result: AcquireRegenerationResult = { kind: "terminal" };

    await this.database.runTransaction(async (transaction) => {
      const [jobSnapshot, recordingSnapshot, preferenceSnapshot] =
        await Promise.all([
          transaction.get(jobRef),
          transaction.get(recordingRef),
          transaction.get(preferenceRef),
        ]);

      if (!recordingSnapshot.exists) {
        result = { kind: "terminal" };
        return;
      }

      if (jobSnapshot.exists) {
        const status: unknown = jobSnapshot.get("status");
        if (status === "completed") {
          result = { kind: "complete" };
          return;
        }
        if (status === "failedTerminal") {
          result = { kind: "terminal" };
          return;
        }

        const activeJobId: unknown = recordingSnapshot.get(
          "activeNoteRegenerationJobId",
        );
        if (activeJobId !== id) {
          transaction.update(jobRef, {
            status: "failedTerminal",
            lastError: {
              code: "note-regeneration/superseded",
              message: "A newer note regeneration replaced this request.",
              retryable: false,
            },
            leaseUntil: FieldValue.delete(),
            updatedAt: FieldValue.serverTimestamp(),
          });
          result = { kind: "terminal" };
          return;
        }

        const attemptCountValue: unknown = jobSnapshot.get("attemptCount");
        const attemptCount =
          typeof attemptCountValue === "number" ? attemptCountValue : 0;
        if (attemptCount >= MAX_REGENERATION_ATTEMPTS) {
          transaction.update(jobRef, {
            status: "failedTerminal",
            leaseUntil: FieldValue.delete(),
            updatedAt: FieldValue.serverTimestamp(),
          });
          transaction.update(recordingRef, {
            noteState: "failed",
            processingError: {
              code: "note-regeneration/exhausted",
              message:
                "Processing could not be completed after several attempts.",
              retryable: false,
            },
            errorMessage:
              "Processing could not be completed after several attempts.",
            updatedAt: FieldValue.serverTimestamp(),
          });
          result = { kind: "terminal" };
          return;
        }

        const leaseValue: unknown = jobSnapshot.get("leaseUntil");
        if (
          leaseValue instanceof Timestamp &&
          leaseValue.toMillis() > nowMilliseconds
        ) {
          throw new RetryablePipelineError(
            "note-regeneration/lease-active",
            "Another invocation owns the note regeneration lease.",
          );
        }

        const transcriptVersionValue: unknown =
          jobSnapshot.get("transcriptVersion");
        const preferencesValue: unknown = jobSnapshot.get("preferences");
        if (
          typeof transcriptVersionValue !== "string" ||
          typeof preferencesValue !== "object" ||
          preferencesValue === null
        ) {
          throw new TerminalPipelineError(
            "note-regeneration/invalid-job",
            "The note regeneration job is malformed.",
          );
        }
        const preferenceData = preferencesValue as Record<string, unknown>;
        const preferences: NotePreferencesSnapshot = {
          globalInstructions: instructions(
            preferenceData.globalInstructions,
          ),
          recordingInstructions: instructions(
            preferenceData.recordingInstructions,
          ),
          capturedAtIso:
            typeof preferenceData.capturedAtIso === "string"
              ? preferenceData.capturedAtIso
              : new Date(nowMilliseconds).toISOString(),
        };

        transaction.update(jobRef, {
          status: "running",
          attemptCount: FieldValue.increment(1),
          leaseUntil: Timestamp.fromMillis(nowMilliseconds + 8 * 60_000),
          updatedAt: FieldValue.serverTimestamp(),
        });
        transaction.update(recordingRef, {
          noteState: "in_progress",
          processingError: FieldValue.delete(),
          updatedAt: FieldValue.serverTimestamp(),
        });
        result = {
          kind: "acquired",
          job: {
            id,
            uid,
            recordingId,
            transcriptVersion: transcriptVersionValue,
            preferences,
            attemptCount: attemptCount + 1,
          },
        };
        return;
      }

      if (
        recordingSnapshot.get("noteState") !== "queued" ||
        recordingSnapshot.get("transcriptionState") !== "completed"
      ) {
        result = { kind: "terminal" };
        return;
      }

      const transcriptVersionValue: unknown =
        recordingSnapshot.get("transcriptVersion");
      if (
        typeof transcriptVersionValue !== "string" ||
        transcriptVersionValue === ""
      ) {
        transaction.update(recordingRef, {
          noteState: "failed",
          processingError: {
            code: "transcript/missing",
            message: "The stored transcript could not be loaded.",
            retryable: false,
          },
          errorMessage: "The stored transcript could not be loaded.",
          updatedAt: FieldValue.serverTimestamp(),
        });
        result = { kind: "terminal" };
        return;
      }

      const preferences: NotePreferencesSnapshot = {
        globalInstructions: instructions(
          preferenceSnapshot.get("noteInstructions") ??
            preferenceSnapshot.get("instructions"),
        ),
        recordingInstructions: instructions(
          recordingSnapshot.get("noteInstructions"),
        ),
        capturedAtIso: new Date(nowMilliseconds).toISOString(),
      };
      transaction.create(jobRef, {
        uid,
        recordingId,
        transcriptVersion: transcriptVersionValue,
        preferences,
        status: "running",
        attemptCount: 1,
        leaseUntil: Timestamp.fromMillis(nowMilliseconds + 8 * 60_000),
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      transaction.update(recordingRef, {
        activeNoteRegenerationJobId: id,
        noteState: "in_progress",
        processingError: FieldValue.delete(),
        errorMessage: FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      result = {
        kind: "acquired",
        job: {
          id,
          uid,
          recordingId,
          transcriptVersion: transcriptVersionValue,
          preferences,
          attemptCount: 1,
        },
      };
    });

    return result;
  }

  public async readTranscript(job: NoteRegenerationJob): Promise<Transcript> {
    const snapshot = await this.database
      .collection("users")
      .doc(job.uid)
      .collection("recordings")
      .doc(job.recordingId)
      .collection("transcriptChunks")
      .where("processingJobId", "==", job.transcriptVersion)
      .orderBy("sequence", "asc")
      .get();
    const segments = snapshot.docs.map(
      (document) => document.data() as TranscriptSegment,
    );
    if (segments.length === 0) {
      throw new TerminalPipelineError(
        "transcript/missing",
        "The stored transcript could not be loaded.",
      );
    }

    return {
      segments,
      plainText: segments
        .map((segment) => {
          const speaker = segment.speakerLabel.trim();
          const label = speaker === "" ? "" : `${speaker}: `;
          return `[${formatTimestamp(segment.startMilliseconds)}] ${label}${segment.text}`;
        })
        .join("\n"),
      durationMilliseconds:
        segments.at(-1)?.endMilliseconds ?? 0,
    };
  }

  public async complete(
    job: NoteRegenerationJob,
    note: GeneratedNote,
  ): Promise<void> {
    const userRef = this.database.collection("users").doc(job.uid);
    const recordingRef = userRef
      .collection("recordings")
      .doc(job.recordingId);
    const jobRef = this.database
      .collection("noteRegenerationJobs")
      .doc(job.id);
    const rulesSnapshot = await userRef
      .collection("exportRules")
      .where("enabled", "==", true)
      .limit(MAX_AUTOMATIC_EXPORT_RULES)
      .get();
    const rules = rulesSnapshot.docs.flatMap((document) => {
      const data = document.data();
      const destinationType: unknown = data.destinationType;
      if (
        destinationType !== "folder" &&
        destinationType !== "share" &&
        destinationType !== "notion" &&
        destinationType !== "chatgpt"
      ) {
        return [];
      }
      const rule: ExportRule = {
        id: document.id,
        destinationType,
        enabled: true,
        includeNotes: data.includeNotes !== false,
        includeTranscript: data.includeTranscript === true,
      };
      return [rule];
    });

    await this.database.runTransaction(async (transaction) => {
      const recordingSnapshot = await transaction.get(recordingRef);
      if (
        recordingSnapshot.get("activeNoteRegenerationJobId") !== job.id
      ) {
        throw new TerminalPipelineError(
          "note-regeneration/superseded",
          "A newer note regeneration replaced this request.",
        );
      }

      for (const rule of rules) {
        const attemptId = `regen_${job.recordingId}_${job.id.slice(0, 16)}_${rule.id}`;
        transaction.set(
          userRef.collection("exportAttempts").doc(attemptId),
          {
            recordingId: job.recordingId,
            processingJobId: job.transcriptVersion,
            noteRegenerationJobId: job.id,
            ruleId: rule.id,
            destinationType: rule.destinationType,
            includeNotes: rule.includeNotes,
            includeTranscript: rule.includeTranscript,
            state: "waiting_for_device",
            createdAt: FieldValue.serverTimestamp(),
            updatedAt: FieldValue.serverTimestamp(),
          },
          { merge: true },
        );
      }

      transaction.update(recordingRef, {
        noteTitle: note.title,
        noteMarkdown: note.markdown,
        noteVersion: FieldValue.increment(1),
        note: {
          summary: note.summary,
          keyPoints: note.keyPoints,
          decisions: note.decisions,
          actionItems: note.actionItems,
        },
        noteState: "completed",
        exportState:
          rules.length === 0 ? "not_started" : "waiting_for_device",
        activeNoteRegenerationJobId: FieldValue.delete(),
        processingError: FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      transaction.update(jobRef, {
        status: "completed",
        completedAt: FieldValue.serverTimestamp(),
        leaseUntil: FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    });
  }

  public async fail(
    job: NoteRegenerationJob,
    error: ClassifiedError,
  ): Promise<boolean> {
    const exhausted = job.attemptCount >= MAX_REGENERATION_ATTEMPTS;
    const terminal = !error.retryable || exhausted;
    const recordingRef = this.database
      .collection("users")
      .doc(job.uid)
      .collection("recordings")
      .doc(job.recordingId);
    const jobRef = this.database
      .collection("noteRegenerationJobs")
      .doc(job.id);

    await this.database.runTransaction(async (transaction) => {
      const recordingSnapshot = await transaction.get(recordingRef);
      transaction.update(jobRef, {
        status: terminal ? "failedTerminal" : "failedRetryable",
        lastError: {
          code: error.code,
          message: error.message.slice(0, 1_000),
          retryable: error.retryable,
        },
        leaseUntil: FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      if (
        recordingSnapshot.get("activeNoteRegenerationJobId") === job.id
      ) {
        transaction.update(recordingRef, {
          noteState: "failed",
          processingError: safeClientError(error, exhausted),
          errorMessage: safeClientError(error, exhausted).message,
          updatedAt: FieldValue.serverTimestamp(),
        });
      }
    });

    return !terminal;
  }
}
