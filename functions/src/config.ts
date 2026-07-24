/**
 * Runtime configuration.
 *
 * Firebase injects GOOGLE_CLOUD_PROJECT/GCLOUD_PROJECT. Every other value can
 * be overridden with a Cloud Functions environment variable without shipping
 * a new Apple app build. Keep Speech in `eu`; the recognizer resource name and
 * API endpoint must use the same location.
 */
export interface RuntimeConfig {
  functionsRegion: string;
  speechLocation: string;
  speechLanguageCode: string;
  speechModel: string;
  geminiLocation: string;
  geminiModel: string;
  maxRecordingBytes: number;
  pipelineVersion: number;
}

const DEFAULT_MAX_RECORDING_BYTES = 512 * 1024 * 1024;

function positiveInteger(value: string | undefined, fallback: number): number {
  if (value === undefined) {
    return fallback;
  }

  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && parsed > 0 ? parsed : fallback;
}

export function getRuntimeConfig(
  environment: NodeJS.ProcessEnv = process.env,
): RuntimeConfig {
  return {
    functionsRegion: environment.FUNCTIONS_REGION ?? "europe-west1",
    speechLocation: environment.SPEECH_LOCATION ?? "eu",
    speechLanguageCode: environment.SPEECH_LANGUAGE_CODE ?? "en-GB",
    speechModel: environment.SPEECH_MODEL ?? "chirp_3",
    geminiLocation: environment.GEMINI_LOCATION ?? "global",
    geminiModel: environment.GEMINI_MODEL ?? "gemini-3.5-flash",
    maxRecordingBytes: positiveInteger(
      environment.MAX_RECORDING_BYTES,
      DEFAULT_MAX_RECORDING_BYTES,
    ),
    pipelineVersion: 1,
  };
}

export function requireProjectId(
  environment: NodeJS.ProcessEnv = process.env,
): string {
  const projectId =
    environment.GOOGLE_CLOUD_PROJECT ?? environment.GCLOUD_PROJECT;

  if (projectId === undefined || projectId.trim() === "") {
    throw new Error(
      "GOOGLE_CLOUD_PROJECT was not provided by the Firebase runtime.",
    );
  }

  return projectId;
}
