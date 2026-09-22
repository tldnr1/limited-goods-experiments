import { config, arrival, thresholds, browser, primaryNormal, waitingThresholds } from '../common.js';
export { handleSummary, setup } from '../common.js';
// Preserve the original Waiting workload: observe READY, then leave it unused until expiry.
export const options = {
  scenarios: { browsers: arrival(config.rps, `${config.durationSeconds}s`, 'joinPoll') },
  thresholds: thresholds(primaryNormal ? waitingThresholds() : {}),
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
};
export function joinPoll() { browser(); }
