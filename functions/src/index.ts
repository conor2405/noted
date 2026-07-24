import { initializeApp } from "firebase-admin/app";
import { getFunctions } from "firebase-admin/functions";
import {
  logger,
  requiresAPI,
  requiresRole,
  setGlobalOptions,
} from "firebase-functions/v2";
import { onDocumentUpdated } from "firebase-functions/v2/firestore";
import { onObjectFinalized } from "firebase-functions/v2/storage";
import { onTaskDispatched } from "firebase-functions/v2/tasks";

import { getRuntimeConfig, requireProjectId } from "./config.js";
import { classifyError } from "./domain/errors.js";
import { isNoteRegenerationTransition } from "./domain/regeneration.js";
import {
  InvalidSourceObjectError,
  parseRecordingPath,
  processingTaskId,
  validateSourceObject,
} from "./domain/storageObject.js";
import { runRecordingPipeline } from "./pipeline/processRecording.js";
import { GeminiNoteGenerator } from "./services/gemini.js";
import { NoteRegenerationRepository } from "./services/noteRegenerationRepository.js";
import { ProcessingRepository } from "./services/processingRepository.js";
import { FirebaseSourceStorage } from "./services/sourceStorage.js";
import { GoogleSpeechTranscriber } from "./services/speech.js";

initializeApp();

const config = getRuntimeConfig();
const MAX_TASK_ATTEMPTS = 5;

setGlobalOptions({
  region: config.functionsRegion,
  maxInstances: 50,
});

requiresAPI(
  "speech.googleapis.com",
  "Transcribe uploaded recordings with Speech-to-Text V2.",
);
requiresAPI(
  "aiplatform.googleapis.com",
  "Generate structured meeting notes with Gemini on Vertex AI.",
);
requiresAPI(
  "cloudtasks.googleapis.com",
  "Dispatch recording processing outside the Storage event handler.",
);
requiresRole("roles/cloudtasks.enqueuer");
requiresRole("roles/aiplatform.user");
requiresRole("roles/speech.client");
requiresRole("roles/storage.objectUser");
requiresRole("roles/datastore.user");

interface ProcessRecordingTask {
  jobId: string;
}

interface ErrorWithCode {
  code?: unknown;
}

function isTaskAlreadyExists(error: unknown): boolean {
  if (typeof error !== "object" || error === null) {
    return false;
  }

  const code = (error as ErrorWithCode).code;
  return (
    code === "functions/task-already-exists" ||
    code === "task-already-exists" ||
    code === 6
  );
}

export const queueRecordingUpload = onObjectFinalized(
  {
    region: config.functionsRegion,
    memory: "512MiB",
    timeoutSeconds: 120,
    concurrency: 20,
  },
  async (event) => {
    const object = event.data;
    if (
      object.name === undefined ||
      parseRecordingPath(object.name) === null
    ) {
      logger.debug("Ignoring unrelated finalized Storage object.", {
        objectName: object.name,
      });
      return;
    }

    let validated: ReturnType<typeof validateSourceObject>;
    try {
      validated = validateSourceObject(
        {
          bucket: object.bucket,
          name: object.name,
          generation: object.generation,
          contentType: object.contentType,
          size: object.size,
        },
        config.maxRecordingBytes,
      );
    } catch (error: unknown) {
      if (error instanceof InvalidSourceObjectError) {
        logger.warn("Rejected invalid recording upload.", {
          objectName: object.name,
          reason: error.message,
        });
        return;
      }
      throw error;
    }

    const repository = new ProcessingRepository(config);
    const prepared = await repository.prepareJob(
      validated.path,
      validated.source,
    );
    if (!prepared.shouldEnqueue) {
      return;
    }

    const queue = getFunctions().taskQueue<ProcessRecordingTask>(
      `locations/${config.functionsRegion}/functions/processRecording`,
    );
    try {
      await queue.enqueue(
        { jobId: prepared.jobId },
        {
          id: processingTaskId(prepared.jobId),
          dispatchDeadlineSeconds: 1_800,
        },
      );
    } catch (error: unknown) {
      if (!isTaskAlreadyExists(error)) {
        throw error;
      }
    }

    await repository.markTaskEnqueued(prepared.jobId);
  },
);

export const processRecording = onTaskDispatched<ProcessRecordingTask>(
  {
    region: config.functionsRegion,
    memory: "2GiB",
    timeoutSeconds: 1_800,
    concurrency: 4,
    maxInstances: 25,
    invoker: "private",
    retryConfig: {
      maxAttempts: MAX_TASK_ATTEMPTS,
      minBackoffSeconds: 30,
      maxBackoffSeconds: 600,
      maxDoublings: 4,
    },
    rateLimits: {
      maxConcurrentDispatches: 20,
      maxDispatchesPerSecond: 10,
    },
  },
  async (request) => {
    const jobId = request.data?.jobId;
    if (
      typeof jobId !== "string" ||
      !/^[a-f0-9]{64}$/.test(jobId)
    ) {
      logger.warn("Rejected malformed processing task.");
      return;
    }

    const projectId = requireProjectId();
    await runRecordingPipeline(
      jobId,
      {
        repository: new ProcessingRepository(config),
        transcriber: new GoogleSpeechTranscriber(projectId, config),
        noteGenerator: new GeminiNoteGenerator(projectId, config),
        sourceStorage: new FirebaseSourceStorage(),
      },
      {
        retryCount: request.retryCount,
        maxAttempts: MAX_TASK_ATTEMPTS,
      },
    );
  },
);

/**
 * A client requests note regeneration by atomically changing `noteState` from
 * `completed` or `failed` to `queued`. `transcriptionState` must already be
 * `completed`; this trigger never touches Speech-to-Text or the source audio.
 */
export const regenerateNotes = onDocumentUpdated(
  {
    document: "users/{uid}/recordings/{recordingId}",
    region: config.functionsRegion,
    memory: "1GiB",
    timeoutSeconds: 540,
    maxInstances: 25,
    concurrency: 8,
    retry: true,
  },
  async (event) => {
    const change = event.data;
    if (change === undefined) {
      return;
    }

    const beforeNoteState: unknown = change.before.get("noteState");
    const afterNoteState: unknown = change.after.get("noteState");
    const transcriptionState: unknown =
      change.after.get("transcriptionState");
    if (
      !isNoteRegenerationTransition(
        {
          noteState: beforeNoteState,
          transcriptionState: change.before.get("transcriptionState"),
        },
        {
          noteState: afterNoteState,
          transcriptionState,
        },
      )
    ) {
      return;
    }

    const repository = new NoteRegenerationRepository();
    const acquired = await repository.acquire(
      event.id,
      event.params.uid,
      event.params.recordingId,
      Date.now(),
    );
    if (acquired.kind !== "acquired" || acquired.job === undefined) {
      return;
    }

    try {
      const transcript = await repository.readTranscript(acquired.job);
      const generator = new GeminiNoteGenerator(requireProjectId(), config);
      const note = await generator.generate(
        transcript,
        acquired.job.preferences,
      );
      await repository.complete(acquired.job, note);
    } catch (error: unknown) {
      const shouldRetry = await repository.fail(
        acquired.job,
        classifyError(error),
      );
      if (shouldRetry) {
        throw error;
      }
    }
  },
);
