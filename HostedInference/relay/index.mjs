// Deployment entry point for composing the verified relay and hosted gateway in one Worker.
// The deployment-preparation script refuses to package a stale legacy snapshot.
import legacy from './legacy-doubletap.mjs';
import hosted from '../src/gateway.mjs';
import {composeRelay} from '../src/relay.mjs';
export * from './legacy-doubletap.mjs';
export default composeRelay(legacy,hosted);
