import { getStorage } from "firebase-admin/storage";

import type { SourceObject } from "../domain/types.js";

export interface SourceStorage {
  delete(source: SourceObject): Promise<void>;
}

export class FirebaseSourceStorage implements SourceStorage {
  public async delete(source: SourceObject): Promise<void> {
    await getStorage()
      .bucket(source.bucket)
      .file(source.name)
      .delete({
        ifGenerationMatch: source.generation,
        ignoreNotFound: true,
      });
  }
}
