export interface NotePreferencesSnapshot {
  globalInstructions: string;
  recordingInstructions: string;
  capturedAtIso: string;
}

export interface TranscriptSegment {
  sequence: number;
  startMilliseconds: number;
  endMilliseconds?: number;
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
