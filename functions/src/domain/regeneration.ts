export interface NoteStateSnapshot {
  noteState: unknown;
  transcriptionState: unknown;
}

/**
 * Generate once when the client finishes syncing an on-device transcript, or
 * regenerate after an explicit completed/failed -> queued request. Backend
 * writes (`queued` -> `in_progress` -> `completed`/`failed`) cannot loop.
 */
export function isNoteGenerationTransition(
  before: NoteStateSnapshot,
  after: NoteStateSnapshot,
): boolean {
  return (
    after.noteState === "queued" &&
    after.transcriptionState === "completed" &&
    (
      before.transcriptionState !== "completed" ||
      before.noteState === "completed" ||
      before.noteState === "failed"
    )
  );
}
