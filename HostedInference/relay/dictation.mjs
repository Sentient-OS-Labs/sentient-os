// Deployment entry point for Double Tap, dictation, Summarize and Proofread. Preserve the
// verified legacy Worker and Counter export; each added capability has its own activation flag.
import legacy from './legacy-doubletap.mjs';
import {composeDictationRelay} from '../src/dictation-relay.mjs';
export * from './legacy-doubletap.mjs';
export default composeDictationRelay(legacy);
