import http from 'k6/http';
import exec from 'k6/execution';
import { sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';
import { SharedArray } from 'k6/data';

export const config = JSON.parse(open(__ENV.TARGET_CONFIG));
export const fixture = JSON.parse(open(__ENV.TARGET_FIXTURE));
// Keep the small sale metadata per VU; parse the large order list only once per k6 process.
const orders = new SharedArray('target-payment-orders', () => JSON.parse(open(__ENV.TARGET_ORDERS)));
export function setup() {
  if (config.scenario === 'business') {
    const saleStart = Date.parse(fixture.sale.opensAt);
    if (!Number.isFinite(saleStart)) throw new Error('Business sale opensAt missing');
    sleep(Math.max(0, (saleStart - Date.now()) / 1000));
    console.log(`TARGET_SALE_START=${saleStart}`);
  }
  const startedAt = Date.now();
  console.log(`TARGET_MEASUREMENT_START=${startedAt}`);
  return { startedAt };
}
const waitingUrl = 'http://nginx';
const checkoutUrl = 'http://checkout-nginx';
const started = new Counter('target_started');
const finished = new Counter('target_finished');
const outcomes = new Counter('target_outcomes');
const ready = new Counter('target_ready');
const held = new Counter('target_held');
const accepted = new Counter('target_payment_accepted');
const unexpected = new Rate('target_unexpected');
const paymentFailures = new Rate('target_payment_rejected');
const purchaseFailures = new Rate('target_purchase_rejected');
const joinAccepted = new Counter('target_join_accepted');
const joinFailures = new Rate('target_join_rejected');
const latency = new Trend('target_latency', true);
const acceptedLatency = new Trend('target_purchase_accepted_ms', true);
const paymentLatency = new Trend('target_payment_ms', true);
const paymentAcceptedLatency = new Trend('target_payment_accepted_ms', true);

export const primaryNormal = config.variant === 'normal' && Number(config.mockPgDelayMs || 0) === 0;
export function waitingThresholds() {
  return Object.fromEntries(['waiting_join', 'waiting_poll'].flatMap(endpoint => [
    [`target_latency{endpoint:${endpoint}}`, ['p(99)<=1000']],
    [`target_unexpected{endpoint:${endpoint}}`, ['rate==0']],
  ]));
}
export function paymentThresholds() {
  return { target_payment_accepted_ms: ['p(95)<=1000'],
    'target_unexpected{endpoint:payment_accept}': ['rate==0'] };
}

export function thresholds(extra = {}) {
  return {
    dropped_iterations: ['count==0'],
    ...(primaryNormal ? { target_unexpected: ['rate<=0.001'] } : {}),
    ...extra,
  };
}

export function arrival(rate, duration, execName, startTime = '0s', timeUnit = '1s') {
  return { executor: 'constant-arrival-rate', rate, timeUnit, duration, startTime,
    preAllocatedVUs: config.vus, maxVUs: config.maxVus, exec: execName, gracefulStop: '420s' };
}

// Per-user deterministic jitter and behavior, independent of VU scheduling.
export function fraction(index, salt = 0) {
  let n = (index + config.seed + salt) | 0;
  n = Math.imul(n ^ (n >>> 16), 0x45d9f3b);
  n = Math.imul(n ^ (n >>> 16), 0x45d9f3b);
  return ((n ^ (n >>> 16)) >>> 0) / 4294967296;
}

function request(method, path, body, user, key, name, ticket) {
  const headers = { 'Content-Type': 'application/json', 'X-User-Id': user, 'Idempotency-Key': key };
  if (ticket) headers['X-Admission-Ticket'] = ticket;
  const response = http.request(method, (name.startsWith('waiting_') ? waitingUrl : checkoutUrl) + path,
    body ? JSON.stringify(body) : null, { headers, timeout: config.scenario === 'priming' ? '15s' : '5s', tags: { name }, responseCallback: http.expectedStatuses(200, 201, 202, 404, 409, 429) });
  let value = {};
  try { value = response.json() || {}; } catch (_) { /* A network/upstream failure has no JSON body. */ }
  const known409 = ['SOLD_OUT', 'TEMPORARILY_UNAVAILABLE', 'ADMISSION_EXPIRED', 'HOLD_EXPIRED', 'USER_LIMIT_EXCEEDED'];
  const bad = response.status === 0 || response.status >= 500 ||
    (response.status >= 400 && response.status !== 429 &&
      !(response.status === 404 && name === 'waiting_poll') &&
      !(response.status === 409 && known409.includes(value.code)));
  unexpected.add(bad, { endpoint: name });
  outcomes.add(1, { endpoint: name, status: String(response.status), result: value.state || value.code || 'ok' });
  latency.add(response.timings.duration, { endpoint: name, status: String(response.status), stage: exec.scenario.name });
  return { response, value };
}

function pause(view, index, attempt = 0) {
  sleep(Math.max(1, Number(view.retryAfter || 1)) + 0.01 + fraction(index, attempt) * 0.24);
}

export function payment(order, index, scenario = 'SUCCESS') {
  let result;
  for (let attempt = 0; attempt < 5; attempt++) {
    result = request('POST', `/api/orders/${order.id}/payments`, { scenario }, order.user, 'payment', 'payment_accept');
    paymentLatency.add(result.response.timings.duration);
    if (result.response.status === 202) {
      accepted.add(1);
      paymentAcceptedLatency.add(result.response.timings.duration, { stage: exec.scenario.name });
      break;
    }
    if (![0, 429, 503].includes(result.response.status)) break;
    sleep(Math.pow(2, attempt) * 0.1 + fraction(index, attempt) * 0.25);
  }
  paymentFailures.add(result.response.status !== 202);
}

export function existingPayment() {
  const index = exec.scenario.iterationInTest;
  started.add(1);
  if (index >= orders.length) throw new Error('Payment fixture exhausted');
  payment(orders[index], index);
  finished.add(1);
}

// Diagnostic only: one new user, one registration, no retries/poll/purchase.
export function joinOnly() {
  const index = exec.scenario.iterationInTest;
  const user = `${config.runId}-${exec.scenario.name}-${index}`;
  const body = { saleId: fixture.sale.id, items: [{ saleItemId: fixture.sale.items[0].id, quantity: 1 }] };
  started.add(1);
  const join = request('POST', '/api/admissions', body, user, 'purchase', 'waiting_join');
  const accepted = join.response.status === 202 && join.value.state === 'WAITING' &&
    typeof join.value.id === 'string' && join.value.id.length > 0;
  joinAccepted.add(accepted ? 1 : 0);
  joinFailures.add(!accepted);
  finished.add(1);
}

export function browser(purchase = false, pay = false, timing = {}) {
  const index = exec.scenario.iterationInTest;
  const user = `${config.runId}-${exec.scenario.name}-${index}`;
  const body = { saleId: fixture.sale.id, items: [{ saleItemId: fixture.sale.items[0].id, quantity: 1 }] };
  const deadline = Date.now() + 180000;
  started.add(1);
  let registration = null;
  let rejoins = 0;
  let order = null;
  let lastTicket = null;
  while (Date.now() < deadline && rejoins < 5) {
    if (!registration) {
      const join = request('POST', '/api/admissions', body, user, 'purchase', 'waiting_join');
      rejoins++;
      if (join.response.status !== 202) {
        if ([429, 503, 0].includes(join.response.status)) { pause(join.value, index, rejoins); continue; }
        break;
      }
      registration = join.value;
      if (!purchase && config.variant === 'abandon' && fraction(index) < 0.5) break;
    }
    pause(registration, index, rejoins);
    const poll = request('GET', `/api/admissions/${registration.id}`, null, user, 'purchase', 'waiting_poll');
    if (poll.response.status === 404 || poll.value.state === 'EXPIRED') { registration = null; continue; }
    if (poll.response.status !== 200) {
      if ([429, 503, 0].includes(poll.response.status)) continue;
      break;
    }
    registration = poll.value;
    if (registration.state === 'SOLD_OUT') break;
    if (registration.state !== 'READY') continue;
    if (registration.ticket !== lastTicket) { ready.add(1); lastTicket = registration.ticket; }
    if (!purchase) break; // Unused READY expires; never synthesize a stock hold.
    for (let attempt = 0; attempt < 5 && Date.now() < registration.expiresAt; attempt++) {
      const bought = request('POST', '/api/purchases', body, user, 'purchase', 'purchase', registration.ticket);
      purchaseFailures.add(bought.response.status !== 201);
      if (bought.response.status === 201) {
        order = { ...bought.value, user };
        held.add(1);
        acceptedLatency.add(bought.response.timings.duration);
        if (config.variant === 'retry') {
          const replay = request('POST', '/api/purchases', body, user, 'purchase', 'purchase_replay', registration.ticket);
          unexpected.add(replay.response.status !== 201 || replay.value.id !== order.id);
        }
        break;
      }
      if (![0, 429, 503].includes(bought.response.status)) break;
      sleep(Math.pow(2, attempt) * 0.1 + fraction(index, attempt) * 0.25);
    }
    if (order) break;
    registration = null; // Same user/key/body; a lost success remains an idempotent replay.
  }
  if (order && pay) {
    const behavior = fraction(index, 99);
    const returning = exec.scenario.name === 'returning';
    if (config.variant === 'abandon' && !returning && behavior < 0.2) {
      outcomes.add(1, { endpoint: 'browser', status: '0', result: 'abandoned_hold' });
    } else {
      if (config.variant === 'late-payment') {
        sleep(Math.max(0, (Date.parse(order.holdExpiresAt) - Date.now()) / 1000 - 1));
      } else if (config.variant === 'burst') {
        sleep(Math.max(0, 60 - (Date.now() - timing.startedAt) / 1000));
      } else if (!returning && !['priming', 'warmup'].includes(config.scenario)) {
        sleep(1 + behavior * 44);
      }
      const pg = config.variant === 'pg-failure'
        ? (behavior < 0.1 ? 'UNKNOWN' : behavior < 0.2 ? 'FAILURE' : behavior < 0.3 ? 'LOST_RESPONSE' : behavior < 0.4 ? 'DELAYED_SUCCESS' : 'SUCCESS')
        : 'SUCCESS';
      payment(order, index, pg);
    }
  }
  finished.add(1);
}

export function handleSummary(data) {
  return { '/results/k6-summary.json': JSON.stringify(data, null, 2) };
}
