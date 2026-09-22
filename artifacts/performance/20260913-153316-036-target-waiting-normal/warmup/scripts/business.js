import { config, arrival, thresholds, browser, primaryNormal, paymentThresholds, waitingThresholds } from './common.js';
export { handleSummary, setup } from './common.js';
const scenarios = {
  opening: arrival(config.users * 0.6, '5s', 'buyPay', '0s', '5s'),
  middle: arrival(config.users * 0.3, '10s', 'buyPay', '5s', '10s'),
  tail: arrival(config.users * 0.1, '45s', 'buyPay', '15s', '45s'),
};
if (config.variant === 'abandon') {
  scenarios.returning = arrival(config.stock, '60s', 'buyPay', '300s', '60s');
}
export const options = { scenarios, setupTimeout: '120s', thresholds: thresholds({
  ...(config.variant !== 'late-payment' ? { target_payment_rejected: ['rate==0'] } : {}),
  ...(primaryNormal ? { target_purchase_accepted_ms: ['p(99)<=1000'], ...paymentThresholds(), ...waitingThresholds() } : {}),
}) };
export function buyPay(timing) { browser(true, true, timing); }
