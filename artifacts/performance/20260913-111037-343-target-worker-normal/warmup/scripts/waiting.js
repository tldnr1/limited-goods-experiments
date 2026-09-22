import { config, arrival, thresholds, browser, primaryNormal, waitingThresholds } from './common.js';
export { handleSummary, setup } from './common.js';
export const options = { scenarios: { browsers: arrival(config.rps, `${config.durationSeconds}s`, 'joinPoll') }, thresholds: thresholds(primaryNormal ? waitingThresholds() : {}) };
export function joinPoll() { browser(); }
