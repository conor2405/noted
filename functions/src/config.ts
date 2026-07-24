/**
 * Runtime configuration.
 *
 * Firebase injects GOOGLE_CLOUD_PROJECT/GCLOUD_PROJECT. Every other value can
 * be overridden with a Cloud Functions environment variable without shipping
 * a new Apple app build. Transcription is performed on the user's Apple device;
 * the backend receives only timestamped transcript chunks.
 */
export interface RuntimeConfig {
  functionsRegion: string;
  geminiLocation: string;
  geminiModel: string;
}

export function getRuntimeConfig(
  environment: NodeJS.ProcessEnv = process.env,
): RuntimeConfig {
  return {
    functionsRegion: environment.FUNCTIONS_REGION ?? "europe-west1",
    geminiLocation: environment.GEMINI_LOCATION ?? "global",
    geminiModel: environment.GEMINI_MODEL ?? "gemini-3.5-flash",
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
