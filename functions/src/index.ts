import { initializeApp } from "firebase-admin/app";
import {
  requiresAPI,
  requiresRole,
  setGlobalOptions,
} from "firebase-functions/v2";
import { onDocumentUpdated } from "firebase-functions/v2/firestore";

import { getRuntimeConfig, requireProjectId } from "./config.js";
import { classifyError } from "./domain/errors.js";
import { isNoteGenerationTransition } from "./domain/regeneration.js";
import { GeminiNoteGenerator } from "./services/gemini.js";
import { NoteRegenerationRepository } from "./services/noteRegenerationRepository.js";

initializeApp();

const config = getRuntimeConfig();

setGlobalOptions({
  region: config.functionsRegion,
  maxInstances: 50,
});

requiresAPI(
  "aiplatform.googleapis.com",
  "Generate structured meeting notes with Gemini on Vertex AI.",
);
requiresRole("roles/aiplatform.user");
requiresRole("roles/datastore.user");

/**
 * The Apple client transcribes locally, stores timestamped chunks, and then
 * atomically marks transcriptionState completed. This trigger performs the
 * only cloud model step: generating (or explicitly regenerating) the note.
 */
export const generateNotes = onDocumentUpdated(
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

    if (
      !isNoteGenerationTransition(
        {
          noteState: change.before.get("noteState"),
          transcriptionState: change.before.get("transcriptionState"),
        },
        {
          noteState: change.after.get("noteState"),
          transcriptionState: change.after.get("transcriptionState"),
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
