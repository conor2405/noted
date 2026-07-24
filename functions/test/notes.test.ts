import { describe, expect, it } from "vitest";

import { parseGeneratedNote } from "../src/domain/notes.js";

describe("structured Gemini notes", () => {
  it("normalizes valid structured output", () => {
    const note = parseGeneratedNote({
      title: "  Weekly planning  ",
      markdown: "# Weekly planning\n\nSummary.",
      summary: "Summary.",
      keyPoints: ["One", 2, "Two"],
      decisions: ["Ship Friday"],
      actionItems: [
        { text: "Prepare release", owner: "Aoife", dueDate: "2026-07-31" },
        { text: "Unassigned", owner: "", dueDate: null },
        { owner: "Ignored" },
      ],
    });

    expect(note.title).toBe("Weekly planning");
    expect(note.keyPoints).toEqual(["One", "Two"]);
    expect(note.actionItems).toEqual([
      {
        text: "Prepare release",
        owner: "Aoife",
        dueDate: "2026-07-31",
      },
      { text: "Unassigned", owner: null, dueDate: null },
    ]);
  });

  it("rejects malformed required fields", () => {
    expect(() =>
      parseGeneratedNote({ title: "", markdown: "", summary: "" }),
    ).toThrow("invalid note schema");
  });
});
