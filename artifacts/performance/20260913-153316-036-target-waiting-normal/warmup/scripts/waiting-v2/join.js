import { config, arrival, thresholds, joinOnly, primaryNormal } from '../common.js';
export { handleSummary, setup } from '../common.js';
export const options = {
  scenarios: { registrations: arrival(config.rps, `${config.durationSeconds}s`, 'join') },
  thresholds: thresholds({
    target_join_rejected: ['rate==0'],
    ...(primaryNormal ? {
      'target_latency{endpoint:waiting_join}': ['p(99)<=1000'],
      'target_unexpected{endpoint:waiting_join}': ['rate==0'],
    } : {}),
  }),
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
};
export function join() { joinOnly(); }
