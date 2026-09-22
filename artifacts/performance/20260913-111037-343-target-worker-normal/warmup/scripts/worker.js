import { config, arrival, thresholds, existingPayment, primaryNormal, paymentThresholds } from './common.js';
export { handleSummary, setup } from './common.js';
export const options = {
  scenarios: { payments: arrival(config.rps, `${config.durationSeconds}s`, 'pay') },
  thresholds: thresholds({ target_payment_rejected: ['rate==0'], ...(primaryNormal ? paymentThresholds() : {}) }),
};
export const pay = existingPayment;
