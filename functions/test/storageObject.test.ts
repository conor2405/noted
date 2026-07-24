import { describe, expect, it } from "vitest";

import {
  InvalidSourceObjectError,
  parseRecordingPath,
  processingJobId,
  processingTaskId,
  validateSourceObject,
} from "../src/domain/storageObject.js";

describe("recording storage object validation", () => {
  it("parses the only accepted source path", () => {
    expect(
      parseRecordingPath("recordings/user_1/meeting-2/source.m4a"),
    ).toEqual({ uid: "user_1", recordingId: "meeting-2" });
    expect(
      parseRecordingPath("recordings/user_1/meeting-2/edited.m4a"),
    ).toBeNull();
    expect(
      parseRecordingPath("exports/user_1/meeting-2/source.m4a"),
    ).toBeNull();
  });

  it("builds a validated source and deterministic identifiers", () => {
    const validated = validateSourceObject(
      {
        bucket: "noted.appspot.com",
        name: "recordings/user_1/meeting-2/source.m4a",
        generation: "1234",
        contentType: "audio/mp4",
        size: "1024",
      },
      2_048,
    );

    expect(validated.source.gcsUri).toBe(
      "gs://noted.appspot.com/recordings/user_1/meeting-2/source.m4a",
    );
    expect(validated.source.sizeBytes).toBe(1_024);
    const first = processingJobId(validated.source);
    expect(first).toHaveLength(64);
    expect(processingJobId(validated.source)).toBe(first);
    expect(processingTaskId(first)).toBe(`recording-${first}`);
  });

  it("rejects unsupported media and oversized files", () => {
    expect(() =>
      validateSourceObject(
        {
          bucket: "noted.appspot.com",
          name: "recordings/user/meeting/source.m4a",
          generation: "1",
          contentType: "text/plain",
          size: 10,
        },
        100,
      ),
    ).toThrow(InvalidSourceObjectError);

    expect(() =>
      validateSourceObject(
        {
          bucket: "noted.appspot.com",
          name: "recordings/user/meeting/source.m4a",
          generation: "1",
          contentType: "audio/x-m4a",
          size: 101,
        },
        100,
      ),
    ).toThrow("Recording size must be between");
  });
});
