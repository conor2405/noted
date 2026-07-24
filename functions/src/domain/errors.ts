export class TerminalPipelineError extends Error {
  public readonly code: string;

  public constructor(code: string, message: string) {
    super(message);
    this.name = "TerminalPipelineError";
    this.code = code;
  }
}

export class RetryablePipelineError extends Error {
  public readonly code: string;

  public constructor(code: string, message: string) {
    super(message);
    this.name = "RetryablePipelineError";
    this.code = code;
  }
}

interface ErrorWithCode {
  code?: unknown;
  message?: unknown;
}

export interface ClassifiedError {
  code: string;
  message: string;
  retryable: boolean;
}

const TERMINAL_GOOGLE_CODES = new Set([
  3, // INVALID_ARGUMENT
  5, // NOT_FOUND
  7, // PERMISSION_DENIED
  9, // FAILED_PRECONDITION
  11, // OUT_OF_RANGE
  12, // UNIMPLEMENTED
  16, // UNAUTHENTICATED
]);

export function classifyError(error: unknown): ClassifiedError {
  if (error instanceof TerminalPipelineError) {
    return { code: error.code, message: error.message, retryable: false };
  }
  if (error instanceof RetryablePipelineError) {
    return { code: error.code, message: error.message, retryable: true };
  }

  const candidate =
    typeof error === "object" && error !== null
      ? (error as ErrorWithCode)
      : {};
  const numericCode =
    typeof candidate.code === "number" ? candidate.code : null;
  const rawCode =
    typeof candidate.code === "string" ? candidate.code : "internal";
  const rawMessage =
    typeof candidate.message === "string"
      ? candidate.message
      : "Unexpected processing failure.";

  return {
    code: numericCode === null ? rawCode : `google/${String(numericCode)}`,
    message: rawMessage,
    retryable:
      numericCode === null ? true : !TERMINAL_GOOGLE_CODES.has(numericCode),
  };
}

export function safeClientError(
  error: ClassifiedError,
  exhausted: boolean,
): { code: string; message: string; retryable: boolean } {
  return {
    code: error.code,
    message: exhausted
      ? "Processing could not be completed after several attempts."
      : error.retryable
        ? "Processing was interrupted and will retry automatically."
        : "This recording could not be processed.",
    retryable: error.retryable && !exhausted,
  };
}
