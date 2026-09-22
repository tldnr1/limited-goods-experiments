import { browser, config } from './common.js';
export { handleSummary, setup } from './common.js';
// One serial transaction; the harness waits for durable confirmation before warmup.
export const options = {
  scenarios: { priming: { executor: 'shared-iterations', vus: 1, iterations: config.iterations,
    exec: 'buyPay', maxDuration: `${config.durationSeconds}s`, gracefulStop: '0s' } },
  thresholds: { target_unexpected: ['rate==0'], target_payment_rejected: ['rate==0'] },
};
export function buyPay(timing) { browser(true, true, timing); }
