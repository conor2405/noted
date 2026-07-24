import { createHash } from "node:crypto";

import type { RecordingPath, SourceObject } from "./types.js";

const SOURCE_PATH =
  /^recordings\/([A-Za-z0-9:_-]{1,128})\/([A-Za-z0-9_-]{1,128})\/source\.m4a$/;
const ACCEPTED_CONTENT_TYPES = new Set([
  "audio/mp4",
  "audio/m4a",
  "audio/x-m4a",
]);

export interface FinalizedObjectInput {
  bucket?: string | undefined;
  name?: string | undefined;
  generation?: string | number | undefined;
  contentType?: string | undefined;
  size?: string | number | undefined;
}

export class InvalidSourceObjectError extends Error {
  public constructor(message: string) {
    super(message);
    this.name = "InvalidSourceObjectError";
  }
}

export function parseRecordingPath(name: string): RecordingPath | null {
  const match = SOURCE_PATH.exec(name);
  if (match === null) {
    return null;
  }

  const uid = match[1];
  const recordingId = match[2];
  if (uid === undefined || recordingId === undefined) {
    return null;
  }

  return { uid, recordingId };
}

export function validateSourceObject(
  input: FinalizedObjectInput,
  maxRecordingBytes: number,
): { path: RecordingPath; source: SourceObject } {
  if (
    input.bucket === undefined ||
    input.name === undefined ||
    input.generation === undefined
  ) {
    throw new InvalidSourceObjectError(
      "Finalized object is missing bucket, name, or generation.",
    );
  }

  const path = parseRecordingPath(input.name);
  if (path === null) {
    throw new InvalidSourceObjectError(
      "Object path does not match recordings/{uid}/{rid}/source.m4a.",
    );
  }

  const contentType = input.contentType?.toLowerCase() ?? "";
  if (!ACCEPTED_CONTENT_TYPES.has(contentType)) {
    throw new InvalidSourceObjectError(
      `Unsupported recording content type: ${contentType || "missing"}.`,
    );
  }

  const sizeBytes = Number(input.size);
  if (
    !Number.isSafeInteger(sizeBytes) ||
    sizeBytes <= 0 ||
    sizeBytes > maxRecordingBytes
  ) {
    throw new InvalidSourceObjectError(
      `Recording size must be between 1 and ${String(maxRecordingBytes)} bytes.`,
    );
  }

  const source: SourceObject = {
    bucket: input.bucket,
    name: input.name,
    generation: String(input.generation),
    contentType,
    sizeBytes,
    gcsUri: `gs://${input.bucket}/${input.name}`,
  };

  return { path, source };
}

export function processingJobId(source: SourceObject): string {
  return createHash("sha256")
    .update(`${source.bucket}\n${source.name}\n${source.generation}`)
    .digest("hex");
}

export function processingTaskId(jobId: string): string {
  return `recording-${jobId}`;
}
