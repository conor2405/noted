export interface NoteStateSnapshot {
  noteState: unknown;
  transcriptionState: unknown;
}

/**
 * Only an explicit client transition requests regeneration. Backend writes
 * (`queued` -> `in_progress` -> `completed`/`failed`) cannot loop back in.
 */
export function isNoteRegenerationTransition(
  before: NoteStateSnapshot,
  after: NoteStateSnapshot,
): boolean {
  return (
    (before.noteState === "completed" || before.noteState === "failed") &&
    after.noteState === "queued" &&
    after.transcriptionState === "completed"
  );
}
