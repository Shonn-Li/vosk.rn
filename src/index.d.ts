import type { TurboModule } from 'react-native';

// Word with timestamp information
export type WordWithTimestamp = {
  conf: number;
  end: number;
  start: number;
  word: string;
};

type VoskOptions = {
  /**
   * Set of phrases the recognizer will seek on which is the closest one from
   * the record, add `"[unk]"` to the set to recognize phrases striclty.
   */
  grammar?: string[];
  /**
   * Timeout in milliseconds to listen.
   */
  timeout?: number;
  /**
   * Path to save audio recording to.
   */
  audioFilePath?: string;
};

interface VoskInterface extends TurboModule {
  loadModel: (path: string) => Promise<void>;
  unload: () => void;

  start: (options?: VoskOptions) => Promise<void>;
  stop: () => void;
  pause: () => void;
  resume: () => Promise<boolean>;

  addListener: (eventType: string) => void;
  removeListeners: (count: number) => void;
}

export type { VoskInterface, VoskOptions };
