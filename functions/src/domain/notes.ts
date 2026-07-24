import type { GeneratedNote } from "./types.js";

function stringArray(value: unknown): string[] {
  return Array.isArray(value)
    ? value.filter((item): item is string => typeof item === "string")
    : [];
}

function nullableString(value: unknown): string | null {
  return typeof value === "string" && value.trim() !== "" ? value : null;
}

export function parseGeneratedNote(value: unknown): GeneratedNote {
  if (typeof value !== "object" || value === null) {
    throw new Error("Gemini returned a non-object note.");
  }

  const candidate = value as Record<string, unknown>;
  const title = candidate.title;
  const markdown = candidate.markdown;
  const summary = candidate.summary;

  if (
    typeof title !== "string" ||
    title.trim() === "" ||
    typeof markdown !== "string" ||
    markdown.trim() === "" ||
    typeof summary !== "string"
  ) {
    throw new Error("Gemini returned an invalid note schema.");
  }

  const rawActionItems = Array.isArray(candidate.actionItems)
    ? candidate.actionItems
    : [];
  const actionItems = rawActionItems.flatMap((item) => {
    if (typeof item !== "object" || item === null) {
      return [];
    }

    const action = item as Record<string, unknown>;
    if (typeof action.text !== "string" || action.text.trim() === "") {
      return [];
    }

    return [
      {
        text: action.text,
        owner: nullableString(action.owner),
        dueDate: nullableString(action.dueDate),
      },
    ];
  });

  return {
    title: title.trim(),
    markdown: markdown.trim(),
    summary: summary.trim(),
    keyPoints: stringArray(candidate.keyPoints),
    decisions: stringArray(candidate.decisions),
    actionItems,
  };
}
