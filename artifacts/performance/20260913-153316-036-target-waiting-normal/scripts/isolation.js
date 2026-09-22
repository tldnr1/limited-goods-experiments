import { config, arrival, thresholds, browser, existingPayment, primaryNormal, paymentThresholds } from './common.js';
export { handleSummary, setup } from './common.js';
export const options = {
  scenarios: {
    browsers: arrival(config.rps, `${config.durationSeconds}s`, 'joinPoll'),
    payments: arrival(config.paymentRps, `${config.durationSeconds}s`, 'pay'),
  },
  thresholds: thresholds({ target_payment_rejected: ['rate==0'], ...(primaryNormal ? paymentThresholds() : {}) }),
};
export function joinPoll() { browser(); }
export const pay = existingPayment;
