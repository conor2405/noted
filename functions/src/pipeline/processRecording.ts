import { classifyError } from "../domain/errors.js";
import { hasReached } from "../domain/stateMachine.js";
import type { ProcessingJob, Transcript } from "../domain/types.js";
import type { NoteGenerator } from "../services/gemini.js";
import type { ProcessingRepository } from "../services/processingRepository.js";
import type { SourceStorage } from "../services/sourceStorage.js";
import type { SpeechTranscriber } from "../services/speech.js";

export interface PipelineDependencies {
  repository: ProcessingRepository;
  transcriber: SpeechTranscriber;
  noteGenerator: NoteGenerator;
  sourceStorage: SourceStorage;
}

export interface ProcessRecordingOptions {
  retryCount: number;
  maxAttempts: number;
  nowMilliseconds?: number;
}

export async function runRecordingPipeline(
  jobId: string,
  dependencies: PipelineDependencies,
  options: ProcessRecordingOptions,
): Promise<void> {
  const acquisition = await dependencies.repository.acquireJob(
    jobId,
    options.nowMilliseconds ?? Date.now(),
  );
  if (acquisition.kind !== "acquired" || acquisition.job === undefined) {
    return;
  }

  const job = acquisition.job;
  try {
    await processDurableStages(jobId, job, dependencies);
  } catch (error: unknown) {
    const classified = classifyError(error);
    const exhausted = options.retryCount >= options.maxAttempts - 1;
    await dependencies.repository.recordFailure(
      jobId,
      job,
      classified,
      exhausted,
    );
    if (classified.retryable && !exhausted) {
      throw error;
    }
  }
}

async function processDurableStages(
  jobId: string,
  initialJob: ProcessingJob,
  dependencies: PipelineDependencies,
): Promise<void> {
  let job = initialJob;
  let transcript: Transcript;

  if (!hasReached(job.stage, "transcriptStored")) {
    await dependencies.repository.beginTranscription(jobId);
    let operationName = job.speechOperationName;
    if (operationName === null) {
      operationName = await dependencies.transcriber.start(job.source.gcsUri);
      await dependencies.repository.saveSpeechOperation(jobId, operationName);
      job = { ...job, stage: "transcribing", speechOperationName: operationName };
    }

    transcript = await dependencies.transcriber.wait(
      operationName,
      job.source.gcsUri,
    );
    await dependencies.repository.storeTranscript(jobId, job, transcript);
    job = { ...job, stage: "transcriptStored" };
  } else {
    transcript = await dependencies.repository.readTranscript(jobId, job);
  }

  if (!hasReached(job.stage, "completed")) {
    await dependencies.repository.beginNoteGeneration(jobId);
    const note = await dependencies.noteGenerator.generate(
      transcript,
      job.notePreferencesSnapshot,
    );
    await dependencies.repository.storeNoteAndExportAttempts(jobId, job, note);
    job = { ...job, stage: "completed", sourceDeletionState: "pending" };
  }

  if (job.sourceDeletionState !== "deleted") {
    await dependencies.sourceStorage.delete(job.source);
    await dependencies.repository.markSourceDeletedAndComplete(jobId, job);
  }
}
