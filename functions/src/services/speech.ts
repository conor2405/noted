import { v2 } from "@google-cloud/speech";
import type { protos } from "@google-cloud/speech";

import type { RuntimeConfig } from "../config.js";
import { TerminalPipelineError } from "../domain/errors.js";
import { parseTranscriptResults } from "../domain/transcript.js";
import type { Transcript } from "../domain/types.js";

export interface SpeechTranscriber {
  start(gcsUri: string): Promise<string>;
  wait(operationName: string, gcsUri: string): Promise<Transcript>;
}

export class GoogleSpeechTranscriber implements SpeechTranscriber {
  private readonly client: v2.SpeechClient;

  public constructor(
    private readonly projectId: string,
    private readonly config: RuntimeConfig,
  ) {
    this.client = new v2.SpeechClient({
      apiEndpoint: `${config.speechLocation}-speech.googleapis.com`,
    });
  }

  public async start(gcsUri: string): Promise<string> {
    const [operation] = await this.client.batchRecognize({
      recognizer: `projects/${this.projectId}/locations/${this.config.speechLocation}/recognizers/_`,
      config: {
        autoDecodingConfig: {},
        languageCodes: [this.config.speechLanguageCode],
        model: this.config.speechModel,
        features: {
          enableAutomaticPunctuation: true,
          enableWordTimeOffsets: false,
          enableWordConfidence: false,
          diarizationConfig: {},
          maxAlternatives: 1,
        },
      },
      files: [{ uri: gcsUri }],
      recognitionOutputConfig: {
        inlineResponseConfig: {},
      },
    });

    if (operation.name === undefined || operation.name === "") {
      throw new Error("Speech-to-Text did not return an operation name.");
    }

    return operation.name;
  }

  public async wait(
    operationName: string,
    gcsUri: string,
  ): Promise<Transcript> {
    const operation =
      await this.client.checkBatchRecognizeProgress(operationName);
    const [response] = await operation.promise();
    const fileResult = response.results?.[gcsUri];

    if (fileResult === undefined) {
      throw new TerminalPipelineError(
        "speech/missing-result",
        "Speech-to-Text returned no result for the uploaded audio.",
      );
    }

    if ((fileResult.error?.code ?? 0) !== 0) {
      const error = new Error(
        fileResult.error?.message ?? "Speech-to-Text rejected the audio.",
      ) as Error & { code: number };
      error.code = fileResult.error?.code ?? 13;
      throw error;
    }

    const transcript =
      fileResult.inlineResult?.transcript ?? fileResult.transcript;
    const results: protos.google.cloud.speech.v2.ISpeechRecognitionResult[] =
      transcript?.results ?? [];
    const parsed = parseTranscriptResults(results);

    if (parsed.segments.length === 0) {
      throw new TerminalPipelineError(
        "speech/no-speech",
        "No intelligible speech was found in the recording.",
      );
    }

    return parsed;
  }
}
