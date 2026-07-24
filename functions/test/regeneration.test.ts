import { describe, expect, it } from "vitest";

import { isNoteRegenerationTransition } from "../src/domain/regeneration.js";

describe("note regeneration trigger guard", () => {
  it("accepts only completed/failed to queued with a completed transcript", () => {
    expect(
      isNoteRegenerationTransition(
        { noteState: "completed", transcriptionState: "completed" },
        { noteState: "queued", transcriptionState: "completed" },
      ),
    ).toBe(true);
    expect(
      isNoteRegenerationTransition(
        { noteState: "failed", transcriptionState: "completed" },
        { noteState: "queued", transcriptionState: "completed" },
      ),
    ).toBe(true);
  });

  it("ignores backend state changes and initial work", () => {
    expect(
      isNoteRegenerationTransition(
        { noteState: "queued", transcriptionState: "completed" },
        { noteState: "in_progress", transcriptionState: "completed" },
      ),
    ).toBe(false);
    expect(
      isNoteRegenerationTransition(
        { noteState: undefined, transcriptionState: undefined },
        { noteState: "queued", transcriptionState: "queued" },
      ),
    ).toBe(false);
  });
});
