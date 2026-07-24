import {
  PROCESSING_STAGES,
  type ProcessingStage,
} from "./types.js";

export function stageRank(stage: ProcessingStage): number {
  return PROCESSING_STAGES.indexOf(stage);
}

export function hasReached(
  current: ProcessingStage,
  target: ProcessingStage,
): boolean {
  return stageRank(current) >= stageRank(target);
}

export function canAcquireJob(input: {
  status: string;
  leaseUntilMilliseconds: number | null;
  nowMilliseconds: number;
}): "acquire" | "complete" | "busy" | "terminal" {
  if (input.status === "completed") {
    return "complete";
  }
  if (input.status === "failedTerminal") {
    return "terminal";
  }
  if (
    input.status === "running" &&
    input.leaseUntilMilliseconds !== null &&
    input.leaseUntilMilliseconds > input.nowMilliseconds
  ) {
    return "busy";
  }
  return "acquire";
}
