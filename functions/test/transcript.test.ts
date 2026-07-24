import type { protos } from "@google-cloud/speech";
import { describe, expect, it } from "vitest";

import {
  formatTimestamp,
  parseTranscriptResults,
} from "../src/domain/transcript.js";

describe("Speech V2 transcript parsing", () => {
  it("creates result-precision, speaker-labelled segments", () => {
    const results: protos.google.cloud.speech.v2.ISpeechRecognitionResult[] = [
      {
        resultEndOffset: { seconds: 5 },
        languageCode: "en-GB",
        alternatives: [
          {
            transcript: "Morning everyone.",
            confidence: 0.92,
            words: [
              { word: "Morning", speakerLabel: "1" },
              { word: "everyone", speakerLabel: "1" },
            ],
          },
        ],
      },
      {
        resultEndOffset: { seconds: 65, nanos: 500_000_000 },
        languageCode: "en-GB",
        alternatives: [
          {
            transcript: "The launch stays on Friday.",
            words: [
              { word: "The", speakerLabel: "2" },
              { word: "launch", speakerLabel: "2" },
              { word: "stays", speakerLabel: "2" },
              { word: "Friday", speakerLabel: "1" },
            ],
          },
        ],
      },
    ];

    const transcript = parseTranscriptResults(results);

    expect(transcript.durationMilliseconds).toBe(65_500);
    expect(transcript.segments).toEqual([
      expect.objectContaining({
        sequence: 0,
        startMilliseconds: 0,
        endMilliseconds: 5_000,
        speakerLabel: "1",
        text: "Morning everyone.",
        timestampPrecision: "result",
      }),
      expect.objectContaining({
        sequence: 1,
        startMilliseconds: 5_000,
        endMilliseconds: 65_500,
        speakerLabel: "2",
        text: "The launch stays on Friday.",
        timestampPrecision: "result",
      }),
    ]);
    expect(transcript.plainText).toContain(
      "[00:05] 2: The launch stays on Friday.",
    );
  });

  it("formats short and long timestamps", () => {
    expect(formatTimestamp(9_000)).toBe("00:09");
    expect(formatTimestamp(3_661_000)).toBe("01:01:01");
  });
});
