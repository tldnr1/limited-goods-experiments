import { arrival, browser, config } from './common.js';
export { handleSummary, setup } from './common.js';
// Four fixed arrival windows; RPS controls arrivals, VUs only provide execution slots.
let startSeconds = 0;
export const options = {
  scenarios: Object.fromEntries(config.warmupStages.map((stage, index) => {
    const scenario = { ...arrival(stage.rate, `${stage.durationSeconds}s`, 'buyPay', `${startSeconds}s`),
      preAllocatedVUs: 40, maxVUs: 40 };
    startSeconds += stage.durationSeconds;
    return [`warmup_${index + 1}`, scenario];
  })),
  thresholds: { dropped_iterations: ['count==0'], target_unexpected: ['rate==0'],
    target_payment_rejected: ['rate==0'] },
};
export function buyPay(timing) { browser(true, true, timing); }
