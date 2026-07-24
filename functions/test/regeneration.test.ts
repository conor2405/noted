import { describe, expect, it } from "vitest";

import { isNoteGenerationTransition } from "../src/domain/regeneration.js";

describe("note generation trigger guard", () => {
  it("accepts an initial on-device transcript sync", () => {
    expect(
      isNoteGenerationTransition(
        { noteState: "queued", transcriptionState: "in_progress" },
        { noteState: "queued", transcriptionState: "completed" },
      ),
    ).toBe(true);
  });

  it("accepts completed/failed to queued regeneration requests", () => {
    expect(
      isNoteGenerationTransition(
        { noteState: "completed", transcriptionState: "completed" },
        { noteState: "queued", transcriptionState: "completed" },
      ),
    ).toBe(true);
    expect(
      isNoteGenerationTransition(
        { noteState: "failed", transcriptionState: "completed" },
        { noteState: "queued", transcriptionState: "completed" },
      ),
    ).toBe(true);
  });

  it("ignores backend state changes and initial work", () => {
    expect(
      isNoteGenerationTransition(
        { noteState: "queued", transcriptionState: "completed" },
        { noteState: "in_progress", transcriptionState: "completed" },
      ),
    ).toBe(false);
    expect(
      isNoteGenerationTransition(
        { noteState: undefined, transcriptionState: undefined },
        { noteState: "queued", transcriptionState: "in_progress" },
      ),
    ).toBe(false);
  });
});
