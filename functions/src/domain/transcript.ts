import type { protos } from "@google-cloud/speech";

import type { Transcript, TranscriptSegment } from "./types.js";

type RecognitionResult =
  protos.google.cloud.speech.v2.ISpeechRecognitionResult;
type Duration = protos.google.protobuf.IDuration;

function durationToMilliseconds(duration: Duration | null | undefined): number {
  if (duration === null || duration === undefined) {
    return 0;
  }

  const seconds =
    typeof duration.seconds === "number"
      ? duration.seconds
      : Number(duration.seconds ?? 0);
  const nanos = duration.nanos ?? 0;
  return Math.max(0, Math.round(seconds * 1_000 + nanos / 1_000_000));
}

function dominantSpeaker(
  words:
    | protos.google.cloud.speech.v2.IWordInfo[]
    | null
    | undefined,
): string {
  if (words === null || words === undefined) {
    return "Speaker";
  }

  const counts = new Map<string, number>();
  for (const word of words) {
    const label = word.speakerLabel?.trim();
    if (label !== undefined && label !== "") {
      counts.set(label, (counts.get(label) ?? 0) + 1);
    }
  }

  let selected = "Speaker";
  let selectedCount = 0;
  for (const [label, count] of counts) {
    if (count > selectedCount) {
      selected = label;
      selectedCount = count;
    }
  }

  return selected;
}

/**
 * Converts Speech V2 results into paragraph-sized segments.
 *
 * We deliberately do not enable or persist word offsets. A segment starts at
 * the previous recognition result's end and ends at this result's
 * `resultEndOffset`. Diarization labels are reduced to the dominant speaker for
 * the result. This keeps timestamps honest at result precision.
 */
export function parseTranscriptResults(
  results: readonly RecognitionResult[],
): Transcript {
  const segments: TranscriptSegment[] = [];
  let previousEndMilliseconds = 0;

  for (const result of results) {
    const alternative = result.alternatives?.[0];
    const text = alternative?.transcript?.trim() ?? "";
    const rawEndMilliseconds = durationToMilliseconds(result.resultEndOffset);
    const endMilliseconds = Math.max(
      previousEndMilliseconds,
      rawEndMilliseconds,
    );

    if (text !== "") {
      segments.push({
        sequence: segments.length,
        startMilliseconds: previousEndMilliseconds,
        endMilliseconds,
        speakerLabel: dominantSpeaker(alternative?.words),
        text,
        confidence:
          alternative?.confidence === null ||
          alternative?.confidence === undefined ||
          alternative.confidence === 0
            ? null
            : alternative.confidence,
        languageCode: result.languageCode?.trim() || null,
        timestampPrecision: "result",
      });
    }

    previousEndMilliseconds = endMilliseconds;
  }

  return {
    segments,
    plainText: segments
      .map(
        (segment) =>
          `[${formatTimestamp(segment.startMilliseconds)}] ${segment.speakerLabel}: ${segment.text}`,
      )
      .join("\n"),
    durationMilliseconds: previousEndMilliseconds,
  };
}

export function formatTimestamp(milliseconds: number): string {
  const totalSeconds = Math.max(0, Math.floor(milliseconds / 1_000));
  const hours = Math.floor(totalSeconds / 3_600);
  const minutes = Math.floor((totalSeconds % 3_600) / 60);
  const seconds = totalSeconds % 60;

  return hours > 0
    ? `${String(hours).padStart(2, "0")}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`
    : `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
}
