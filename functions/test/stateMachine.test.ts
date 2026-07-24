import { describe, expect, it } from "vitest";

import {
  canAcquireJob,
  hasReached,
} from "../src/domain/stateMachine.js";

describe("processing job state machine", () => {
  it("orders durable pipeline stages", () => {
    expect(hasReached("queued", "transcriptStored")).toBe(false);
    expect(hasReached("transcriptStored", "transcriptStored")).toBe(true);
    expect(hasReached("completed", "generatingNotes")).toBe(true);
  });

  it("prevents concurrent leases and permits expired retries", () => {
    expect(
      canAcquireJob({
        status: "running",
        leaseUntilMilliseconds: 2_000,
        nowMilliseconds: 1_000,
      }),
    ).toBe("busy");
    expect(
      canAcquireJob({
        status: "running",
        leaseUntilMilliseconds: 500,
        nowMilliseconds: 1_000,
      }),
    ).toBe("acquire");
    expect(
      canAcquireJob({
        status: "completed",
        leaseUntilMilliseconds: null,
        nowMilliseconds: 1_000,
      }),
    ).toBe("complete");
  });
});
