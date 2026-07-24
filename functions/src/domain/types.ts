export const PROCESSING_STAGES = [
  "queued",
  "transcribing",
  "transcriptStored",
  "generatingNotes",
  "completed",
] as const;

export type ProcessingStage = (typeof PROCESSING_STAGES)[number];

export type JobStatus =
  | "pending"
  | "queued"
  | "running"
  | "completed"
  | "failedRetryable"
  | "failedTerminal";

export interface RecordingPath {
  uid: string;
  recordingId: string;
}

export interface SourceObject {
  bucket: string;
  name: string;
  generation: string;
  contentType: string;
  sizeBytes: number;
  gcsUri: string;
}

export interface NotePreferencesSnapshot {
  globalInstructions: string;
  recordingInstructions: string;
  capturedAtIso: string;
}

export interface ProcessingJob {
  uid: string;
  recordingId: string;
  source: SourceObject;
  pipelineVersion: number;
  stage: ProcessingStage;
  status: JobStatus;
  attemptCount: number;
  notePreferencesSnapshot: NotePreferencesSnapshot;
  speechOperationName: string | null;
  sourceDeletionState:
    | "pending"
    | "deleted"
    | "retainedAfterFailure";
}

export interface TranscriptSegment {
  sequence: number;
  startMilliseconds: number;
  endMilliseconds: number;
  speakerLabel: string;
  text: string;
  confidence: number | null;
  languageCode: string | null;
  timestampPrecision: "result";
}

export interface Transcript {
  segments: TranscriptSegment[];
  plainText: string;
  durationMilliseconds: number;
}

export interface GeneratedNote {
  title: string;
  markdown: string;
  summary: string;
  keyPoints: string[];
  decisions: string[];
  actionItems: Array<{
    text: string;
    owner: string | null;
    dueDate: string | null;
  }>;
}

export interface ExportRule {
  id: string;
  destinationType: "folder" | "share" | "notion" | "chatgpt";
  enabled: boolean;
  includeNotes: boolean;
  includeTranscript: boolean;
}
