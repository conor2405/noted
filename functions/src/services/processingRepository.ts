import {
  FieldValue,
  Timestamp,
  getFirestore,
  type DocumentData,
  type DocumentReference,
  type Firestore,
} from "firebase-admin/firestore";

import type { RuntimeConfig } from "../config.js";
import {
  RetryablePipelineError,
  TerminalPipelineError,
  safeClientError,
  type ClassifiedError,
} from "../domain/errors.js";
import { canAcquireJob, hasReached } from "../domain/stateMachine.js";
import { formatTimestamp } from "../domain/transcript.js";
import type {
  ExportRule,
  GeneratedNote,
  NotePreferencesSnapshot,
  ProcessingJob,
  ProcessingStage,
  RecordingPath,
  SourceObject,
  Transcript,
  TranscriptSegment,
} from "../domain/types.js";
import { processingJobId } from "../domain/storageObject.js";

const FAILED_AUDIO_RETENTION_DAYS = 7;
const MAX_AUTOMATIC_EXPORT_RULES = 50;

export interface PrepareJobResult {
  jobId: string;
  shouldEnqueue: boolean;
}

export interface AcquireJobResult {
  kind: "acquired" | "complete" | "terminal";
  job?: ProcessingJob;
}

function nonEmptyString(value: unknown): string | null {
  return typeof value === "string" && value.trim() !== ""
    ? value.trim()
    : null;
}

function boundedInstructions(value: unknown): string {
  return typeof value === "string" ? value.slice(0, 20_000) : "";
}

function recordingRef(
  database: Firestore,
  uid: string,
  recordingId: string,
): DocumentReference {
  return database
    .collection("users")
    .doc(uid)
    .collection("recordings")
    .doc(recordingId);
}

function parseJob(data: DocumentData): ProcessingJob {
  const source = data.source as Partial<SourceObject> | undefined;
  const preferences = data.notePreferencesSnapshot as
    | Partial<NotePreferencesSnapshot>
    | undefined;
  const sourceDeletionState: unknown = data.sourceDeletionState;

  if (
    typeof data.uid !== "string" ||
    typeof data.recordingId !== "string" ||
    typeof data.pipelineVersion !== "number" ||
    typeof data.stage !== "string" ||
    typeof data.status !== "string" ||
    typeof data.attemptCount !== "number" ||
    source === undefined ||
    typeof source.bucket !== "string" ||
    typeof source.name !== "string" ||
    typeof source.generation !== "string" ||
    typeof source.contentType !== "string" ||
    typeof source.sizeBytes !== "number" ||
    typeof source.gcsUri !== "string" ||
    preferences === undefined ||
    typeof preferences.globalInstructions !== "string" ||
    typeof preferences.recordingInstructions !== "string" ||
    typeof preferences.capturedAtIso !== "string"
  ) {
    throw new TerminalPipelineError(
      "job/invalid",
      "The processing job is malformed.",
    );
  }

  return {
    uid: data.uid,
    recordingId: data.recordingId,
    source: {
      bucket: source.bucket,
      name: source.name,
      generation: source.generation,
      contentType: source.contentType,
      sizeBytes: source.sizeBytes,
      gcsUri: source.gcsUri,
    },
    pipelineVersion: data.pipelineVersion,
    stage: data.stage as ProcessingStage,
    status: data.status as ProcessingJob["status"],
    attemptCount: data.attemptCount,
    notePreferencesSnapshot: {
      globalInstructions: preferences.globalInstructions,
      recordingInstructions: preferences.recordingInstructions,
      capturedAtIso: preferences.capturedAtIso,
    },
    speechOperationName: nonEmptyString(data.speechOperationName),
    sourceDeletionState:
      sourceDeletionState === "deleted" ||
      sourceDeletionState === "retainedAfterFailure"
        ? sourceDeletionState
        : "pending",
  };
}

export class ProcessingRepository {
  public constructor(
    private readonly config: RuntimeConfig,
    private readonly database: Firestore = getFirestore(),
  ) {}

  public async prepareJob(
    path: RecordingPath,
    source: SourceObject,
  ): Promise<PrepareJobResult> {
    const jobId = processingJobId(source);
    const jobRef = this.database.collection("processingJobs").doc(jobId);
    const userRecordingRef = recordingRef(
      this.database,
      path.uid,
      path.recordingId,
    );
    const preferenceRef = this.database
      .collection("users")
      .doc(path.uid)
      .collection("preferences")
      .doc("default");
    let shouldEnqueue = false;

    await this.database.runTransaction(async (transaction) => {
      const [jobSnapshot, recordingSnapshot, preferenceSnapshot] =
        await Promise.all([
          transaction.get(jobRef),
          transaction.get(userRecordingRef),
          transaction.get(preferenceRef),
        ]);

      if (jobSnapshot.exists) {
        const status: unknown = jobSnapshot.get("status");
        shouldEnqueue =
          status !== "completed" && status !== "failedTerminal";
        return;
      }

      if (!recordingSnapshot.exists) {
        transaction.create(jobRef, {
          uid: path.uid,
          recordingId: path.recordingId,
          source,
          pipelineVersion: this.config.pipelineVersion,
          stage: "queued",
          status: "failedTerminal",
          attemptCount: 0,
          sourceDeletionState: "retainedAfterFailure",
          cleanupEligibleAt: Timestamp.fromMillis(
            Date.now() + FAILED_AUDIO_RETENTION_DAYS * 86_400_000,
          ),
          lastError: {
            code: "recording/not-found",
            message: "Upload has no matching recording document.",
            retryable: false,
          },
          createdAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
        });
        return;
      }

      const ownerUid: unknown = recordingSnapshot.get("ownerUid");
      if (ownerUid !== undefined && ownerUid !== path.uid) {
        transaction.create(jobRef, {
          uid: path.uid,
          recordingId: path.recordingId,
          source,
          pipelineVersion: this.config.pipelineVersion,
          stage: "queued",
          status: "failedTerminal",
          attemptCount: 0,
          sourceDeletionState: "retainedAfterFailure",
          cleanupEligibleAt: Timestamp.fromMillis(
            Date.now() + FAILED_AUDIO_RETENTION_DAYS * 86_400_000,
          ),
          lastError: {
            code: "recording/owner-mismatch",
            message: "Recording owner does not match the upload path.",
            retryable: false,
          },
          createdAt: FieldValue.serverTimestamp(),
          updatedAt: FieldValue.serverTimestamp(),
        });
        return;
      }

      const preferences: NotePreferencesSnapshot = {
        globalInstructions: boundedInstructions(
          preferenceSnapshot.get("noteInstructions") ??
            preferenceSnapshot.get("instructions"),
        ),
        recordingInstructions: boundedInstructions(
          recordingSnapshot.get("noteInstructions"),
        ),
        capturedAtIso: new Date().toISOString(),
      };

      transaction.create(jobRef, {
        uid: path.uid,
        recordingId: path.recordingId,
        source,
        pipelineVersion: this.config.pipelineVersion,
        stage: "queued",
        status: "pending",
        attemptCount: 0,
        notePreferencesSnapshot: preferences,
        speechOperationName: null,
        sourceDeletionState: "pending",
        createdAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      transaction.update(userRecordingRef, {
        ownerUid: path.uid,
        audioStoragePath: source.name,
        activeProcessingJobId: jobId,
        uploadState: "completed",
        transcriptionState: "queued",
        noteState: "queued",
        exportState: "not_started",
        processingError: FieldValue.delete(),
        errorMessage: FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      shouldEnqueue = true;
    });

    return { jobId, shouldEnqueue };
  }

  public async markTaskEnqueued(jobId: string): Promise<void> {
    await this.database.collection("processingJobs").doc(jobId).update({
      status: "queued",
      taskEnqueuedAt: FieldValue.serverTimestamp(),
      updatedAt: FieldValue.serverTimestamp(),
    });
  }

  public async acquireJob(
    jobId: string,
    nowMilliseconds: number,
  ): Promise<AcquireJobResult> {
    const jobRef = this.database.collection("processingJobs").doc(jobId);
    let result: AcquireJobResult = { kind: "terminal" };

    await this.database.runTransaction(async (transaction) => {
      const jobSnapshot = await transaction.get(jobRef);
      if (!jobSnapshot.exists) {
        throw new TerminalPipelineError(
          "job/not-found",
          "Processing job does not exist.",
        );
      }

      const job = parseJob(jobSnapshot.data() ?? {});
      const lease: unknown = jobSnapshot.get("leaseUntil");
      const leaseUntilMilliseconds =
        lease instanceof Timestamp ? lease.toMillis() : null;
      const decision = canAcquireJob({
        status: job.status,
        leaseUntilMilliseconds,
        nowMilliseconds,
      });

      if (decision === "complete") {
        result = { kind: "complete" };
        return;
      }
      if (decision === "terminal") {
        result = { kind: "terminal" };
        return;
      }
      if (decision === "busy") {
        throw new RetryablePipelineError(
          "job/lease-active",
          "Another task still owns the processing lease.",
        );
      }

      const userRecordingRef = recordingRef(
        this.database,
        job.uid,
        job.recordingId,
      );
      const recordingSnapshot = await transaction.get(userRecordingRef);
      if (
        !recordingSnapshot.exists ||
        recordingSnapshot.get("activeProcessingJobId") !== jobId
      ) {
        transaction.update(jobRef, {
          status: "failedTerminal",
          sourceDeletionState: "retainedAfterFailure",
          cleanupEligibleAt: Timestamp.fromMillis(
            nowMilliseconds + FAILED_AUDIO_RETENTION_DAYS * 86_400_000,
          ),
          lastError: {
            code: "job/superseded",
            message: "A newer upload replaced this processing job.",
            retryable: false,
          },
          leaseUntil: FieldValue.delete(),
          updatedAt: FieldValue.serverTimestamp(),
        });
        result = { kind: "terminal" };
        return;
      }

      transaction.update(jobRef, {
        status: "running",
        attemptCount: FieldValue.increment(1),
        leaseUntil: Timestamp.fromMillis(nowMilliseconds + 25 * 60_000),
        lastStartedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
      result = {
        kind: "acquired",
        job: { ...job, status: "running", attemptCount: job.attemptCount + 1 },
      };
    });

    return result;
  }

  public async beginTranscription(jobId: string): Promise<void> {
    await this.updateStage(jobId, "transcribing", {
      transcriptionState: "in_progress",
    });
  }

  public async saveSpeechOperation(
    jobId: string,
    operationName: string,
  ): Promise<void> {
    await this.database.collection("processingJobs").doc(jobId).update({
      speechOperationName: operationName,
      updatedAt: FieldValue.serverTimestamp(),
    });
  }

  public async storeTranscript(
    jobId: string,
    job: ProcessingJob,
    transcript: Transcript,
  ): Promise<void> {
    const chunks = recordingRef(
      this.database,
      job.uid,
      job.recordingId,
    ).collection("transcriptChunks");
    const existing = await chunks.get();
    const expectedIds = new Set<string>();
    const writer = this.database.bulkWriter();
    const writeOperations: Array<Promise<unknown>> = [];

    for (const segment of transcript.segments) {
      const documentId = String(segment.sequence).padStart(8, "0");
      expectedIds.add(documentId);
      writeOperations.push(
        writer.set(chunks.doc(documentId), {
          ...segment,
          index: segment.sequence,
          processingJobId: jobId,
          createdAt: FieldValue.serverTimestamp(),
        }),
      );
    }

    for (const snapshot of existing.docs) {
      if (!expectedIds.has(snapshot.id)) {
        writeOperations.push(writer.delete(snapshot.ref));
      }
    }
    await Promise.all(writeOperations);
    await writer.close();

    const jobRef = this.database.collection("processingJobs").doc(jobId);
    const userRecordingRef = recordingRef(
      this.database,
      job.uid,
      job.recordingId,
    );
    await this.database.runTransaction(async (transaction) => {
      const recordingSnapshot = await transaction.get(userRecordingRef);
      if (recordingSnapshot.get("activeProcessingJobId") !== jobId) {
        throw new TerminalPipelineError(
          "job/superseded",
          "A newer processing job replaced this transcript.",
        );
      }

      transaction.update(userRecordingRef, {
        transcriptionState: "completed",
        durationMilliseconds: transcript.durationMilliseconds,
        transcriptChunkCount: transcript.segments.length,
        transcriptVersion: jobId,
        updatedAt: FieldValue.serverTimestamp(),
      });
      transaction.update(jobRef, {
        stage: "transcriptStored",
        transcriptStoredAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    });
  }

  public async readTranscript(
    jobId: string,
    job: ProcessingJob,
  ): Promise<Transcript> {
    const snapshot = await recordingRef(
      this.database,
      job.uid,
      job.recordingId,
    )
      .collection("transcriptChunks")
      .where("processingJobId", "==", jobId)
      .orderBy("sequence", "asc")
      .get();
    const segments = snapshot.docs.map(
      (document) => document.data() as TranscriptSegment,
    );

    if (segments.length === 0) {
      throw new RetryablePipelineError(
        "transcript/missing",
        "Stored transcript chunks could not be loaded.",
      );
    }

    return {
      segments,
      plainText: segments
        .map(
          (segment) =>
            `[${formatTimestamp(segment.startMilliseconds)}] ${segment.speakerLabel}: ${segment.text}`,
        )
        .join("\n"),
      durationMilliseconds:
        segments.at(-1)?.endMilliseconds ?? 0,
    };
  }

  public async beginNoteGeneration(jobId: string): Promise<void> {
    await this.updateStage(jobId, "generatingNotes", {
      noteState: "in_progress",
    });
  }

  public async storeNoteAndExportAttempts(
    jobId: string,
    job: ProcessingJob,
    note: GeneratedNote,
  ): Promise<void> {
    const userRef = this.database.collection("users").doc(job.uid);
    const rulesSnapshot = await userRef
      .collection("exportRules")
      .where("enabled", "==", true)
      .limit(MAX_AUTOMATIC_EXPORT_RULES)
      .get();
    const rules = rulesSnapshot.docs.flatMap((document) => {
      const data = document.data();
      const destinationType: unknown = data.destinationType;
      const includeNotes: unknown = data.includeNotes;
      const includeTranscript: unknown = data.includeTranscript;
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
        includeNotes: includeNotes !== false,
        includeTranscript: includeTranscript === true,
      };
      return [rule];
    });
    const jobRef = this.database.collection("processingJobs").doc(jobId);
    const userRecordingRef = recordingRef(
      this.database,
      job.uid,
      job.recordingId,
    );

    await this.database.runTransaction(async (transaction) => {
      const recordingSnapshot = await transaction.get(userRecordingRef);
      if (recordingSnapshot.get("activeProcessingJobId") !== jobId) {
        throw new TerminalPipelineError(
          "job/superseded",
          "A newer processing job replaced these notes.",
        );
      }

      for (const rule of rules) {
        const attemptId = `${job.recordingId}_${jobId.slice(0, 16)}_${rule.id}`;
        transaction.set(
          userRef.collection("exportAttempts").doc(attemptId),
          {
            recordingId: job.recordingId,
            processingJobId: jobId,
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

      transaction.update(userRecordingRef, {
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
        updatedAt: FieldValue.serverTimestamp(),
      });
      transaction.update(jobRef, {
        stage: "completed",
        sourceDeletionState: "pending",
        durableSuccessAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    });
  }

  public async markSourceDeletedAndComplete(
    jobId: string,
    job: ProcessingJob,
  ): Promise<void> {
    const jobRef = this.database.collection("processingJobs").doc(jobId);
    const userRecordingRef = recordingRef(
      this.database,
      job.uid,
      job.recordingId,
    );

    await this.database.runTransaction(async (transaction) => {
      const recordingSnapshot = await transaction.get(userRecordingRef);
      if (recordingSnapshot.get("activeProcessingJobId") === jobId) {
        transaction.update(userRecordingRef, {
          uploadState: "completed",
          updatedAt: FieldValue.serverTimestamp(),
        });
      }
      transaction.update(jobRef, {
        status: "completed",
        sourceDeletionState: "deleted",
        sourceDeletedAt: FieldValue.serverTimestamp(),
        leaseUntil: FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    });
  }

  public async recordFailure(
    jobId: string,
    job: ProcessingJob,
    error: ClassifiedError,
    exhausted: boolean,
  ): Promise<void> {
    const terminal = !error.retryable || exhausted;
    const jobRef = this.database.collection("processingJobs").doc(jobId);
    const userRecordingRef = recordingRef(
      this.database,
      job.uid,
      job.recordingId,
    );

    await this.database.runTransaction(async (transaction) => {
      const [jobSnapshot, recordingSnapshot] = await Promise.all([
        transaction.get(jobRef),
        transaction.get(userRecordingRef),
      ]);
      const persistedJob = jobSnapshot.exists
        ? parseJob(jobSnapshot.data() ?? {})
        : job;
      const jobUpdate: DocumentData = {
        status: terminal ? "failedTerminal" : "failedRetryable",
        lastError: {
          code: error.code,
          message: error.message.slice(0, 1_000),
          retryable: error.retryable,
        },
        lastFailedAt: FieldValue.serverTimestamp(),
        leaseUntil: FieldValue.delete(),
        updatedAt: FieldValue.serverTimestamp(),
      };
      if (terminal) {
        jobUpdate.sourceDeletionState = "retainedAfterFailure";
        jobUpdate.cleanupEligibleAt = Timestamp.fromMillis(
          Date.now() + FAILED_AUDIO_RETENTION_DAYS * 86_400_000,
        );
      }
      transaction.update(jobRef, jobUpdate);

      if (
        recordingSnapshot.exists &&
        recordingSnapshot.get("activeProcessingJobId") === jobId
      ) {
        const transcriptReady = hasReached(
          persistedJob.stage,
          "transcriptStored",
        );
        const noteReady = hasReached(persistedJob.stage, "completed");
        transaction.update(userRecordingRef, {
          transcriptionState: transcriptReady ? "completed" : "failed",
          noteState: noteReady ? "completed" : "failed",
          processingError: safeClientError(error, exhausted),
          errorMessage: safeClientError(error, exhausted).message,
          updatedAt: FieldValue.serverTimestamp(),
        });
      }
    });
  }

  private async updateStage(
    jobId: string,
    stage: ProcessingStage,
    recordingFields: DocumentData,
  ): Promise<void> {
    const jobRef = this.database.collection("processingJobs").doc(jobId);
    await this.database.runTransaction(async (transaction) => {
      const jobSnapshot = await transaction.get(jobRef);
      if (!jobSnapshot.exists) {
        throw new TerminalPipelineError(
          "job/not-found",
          "Processing job does not exist.",
        );
      }

      const job = parseJob(jobSnapshot.data() ?? {});
      const userRecordingRef = recordingRef(
        this.database,
        job.uid,
        job.recordingId,
      );
      const recordingSnapshot = await transaction.get(userRecordingRef);
      if (recordingSnapshot.get("activeProcessingJobId") !== jobId) {
        throw new TerminalPipelineError(
          "job/superseded",
          "A newer processing job replaced this one.",
        );
      }

      if (!hasReached(job.stage, stage)) {
        transaction.update(jobRef, {
          stage,
          updatedAt: FieldValue.serverTimestamp(),
        });
      }
      transaction.update(userRecordingRef, {
        ...recordingFields,
        updatedAt: FieldValue.serverTimestamp(),
      });
    });
  }
}
