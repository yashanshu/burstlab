import http from 'k6/http';
import exec from 'k6/execution';
import { check } from 'k6';
import { Counter } from 'k6/metrics';

const profile = __ENV.PROFILE || 'smoke';
const runID = __ENV.RUN_ID || '';
const baseURL = (__ENV.URL || 'http://127.0.0.1:8080').replace(/\/$/, '');
const targetRPS = positiveInteger('TARGET_RPS', 100);
const preAllocatedVUs = positiveInteger('PRE_ALLOCATED_VUS', 100);
const maxVUs = positiveInteger('MAX_VUS', 1000);
const maxP95MS = positiveNumber('MAX_P95_MS', 150);
const maxFailureRate = fraction('MAX_FAILURE_RATE', 0.005);
const discoveryDuration = __ENV.DISCOVERY_DURATION || '30s';
const lowDuration = __ENV.LOW_DURATION || '2m';
const rampDuration = __ENV.RAMP_DURATION || '3m';
const holdDuration = __ENV.HOLD_DURATION || '10m';
const lowDurationMS = durationMilliseconds('LOW_DURATION', lowDuration);
const rampDurationMS = durationMilliseconds('RAMP_DURATION', rampDuration);
const holdDurationMS = durationMilliseconds('HOLD_DURATION', holdDuration);
const discoveryDurationMS = durationMilliseconds('DISCOVERY_DURATION', discoveryDuration);
const acceptedEvents = new Counter('accepted_events');

if (!/^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$/.test(runID)) {
  throw new Error('RUN_ID must contain 1-32 letters, digits, underscores, or hyphens');
}
if (preAllocatedVUs > maxVUs) {
  throw new Error('PRE_ALLOCATED_VUS cannot exceed MAX_VUS');
}
if (!['smoke', 'health', 'discovery', 'confirmation'].includes(profile)) {
  throw new Error('PROFILE must be smoke, health, discovery, or confirmation');
}
if (profile !== 'health' && !__ENV.TOKEN) {
  throw new Error('TOKEN is required for event profiles');
}

const passRate = 1 - maxFailureRate;
const scenarios = buildScenarios();
const thresholds = buildThresholds();

export const options = {
  discardResponseBodies: true,
  scenarios,
  thresholds,
  summaryTrendStats: ['avg', 'min', 'med', 'max', 'p(90)', 'p(95)', 'p(99)'],
  tags: { profile, run_id: runID },
};

export default function () {
  const phase = currentPhase();

  if (profile === 'health') {
    const response = http.get(`${baseURL}/health/live`, {
      tags: { name: 'GET /health/live', phase },
      timeout: '2s',
    });
    check(response, { 'health returned 200': (result) => result.status === 200 }, { phase });
    return;
  }

  const requestID = `${runID}-${phase}-${exec.scenario.iterationInTest}`;
  const response = http.post(
    `${baseURL}/v1/events`,
    JSON.stringify({
      request_id: requestID,
      event_ts: new Date().toISOString(),
      value: 'course-event',
    }),
    {
      headers: {
        Authorization: `Bearer ${__ENV.TOKEN}`,
        'Content-Type': 'application/json',
      },
      tags: { name: 'POST /v1/events', phase },
      timeout: '2s',
    },
  );
  if (response.status === 202) {
    acceptedEvents.add(1, { phase });
  }
  check(response, { 'event accepted (202)': (result) => result.status === 202 }, { phase });
}

export function handleSummary(data) {
  const path = `results/${runID}-${profile}.summary.json`;
  return {
    stdout: summaryLine(data, path),
    [path]: JSON.stringify(data, null, 2),
  };
}

function buildScenarios() {
  const common = {
    timeUnit: '1s',
    preAllocatedVUs,
    maxVUs,
    gracefulStop: '3s',
  };

  if (profile === 'smoke') {
    return {
      smoke: {
        executor: 'shared-iterations',
        vus: 1,
        iterations: 1,
        maxDuration: '10s',
        tags: { phase: 'smoke' },
      },
    };
  }

  if (profile === 'health') {
    return {
      health: {
        ...common,
        executor: 'constant-arrival-rate',
        rate: targetRPS,
        duration: __ENV.HEALTH_DURATION || '30s',
        tags: { phase: 'health' },
      },
    };
  }

  if (profile === 'discovery') {
    return {
      discovery: {
        ...common,
        executor: 'constant-arrival-rate',
        rate: targetRPS,
        duration: discoveryDuration,
        tags: { phase: 'discovery' },
      },
    };
  }

  const lowRate = Math.max(1, Math.floor(targetRPS / 15));
  return {
    confirmation: {
      ...common,
      executor: 'ramping-arrival-rate',
      startRate: lowRate,
      stages: [
        { target: lowRate, duration: lowDuration },
        { target: targetRPS, duration: rampDuration },
        { target: targetRPS, duration: holdDuration },
      ],
    },
  };
}

function buildThresholds() {
  if (profile === 'smoke') {
    return {
      'checks{phase:smoke}': ['rate==1'],
      'http_req_failed{phase:smoke}': ['rate==0'],
      'http_reqs{phase:smoke}': ['count==1'],
      'accepted_events{phase:smoke}': ['count==1'],
    };
  }

  if (profile === 'health') {
    return {
      'checks{phase:health}': [`rate>${passRate}`],
      'http_req_failed{phase:health}': [`rate<${maxFailureRate}`],
      'http_req_duration{phase:health}': [`p(95)<${maxP95MS}`],
      'http_reqs{phase:health}': ['rate>0'],
      'dropped_iterations{phase:health}': ['count==0'],
    };
  }

  const phase = profile === 'confirmation' ? 'hold' : profile;
  return {
    [`checks{phase:${phase}}`]: [`rate>${passRate}`],
    [`http_req_failed{phase:${phase}}`]: [`rate<${maxFailureRate}`],
    [`http_req_duration{phase:${phase}}`]: [`p(95)<${maxP95MS}`],
    [`http_reqs{phase:${phase}}`]: ['rate>0'],
    [`accepted_events{phase:${phase}}`]: ['count>0'],
    [profile === 'confirmation' ? 'dropped_iterations{scenario:confirmation}' : `dropped_iterations{phase:${phase}}`]: ['count==0'],
  };
}

function positiveInteger(name, fallback) {
  const value = Number(__ENV[name] || fallback);
  if (!Number.isInteger(value) || value < 1) {
    throw new Error(`${name} must be a positive integer`);
  }
  return value;
}

function positiveNumber(name, fallback) {
  const value = Number(__ENV[name] || fallback);
  if (!Number.isFinite(value) || value <= 0) {
    throw new Error(`${name} must be greater than zero`);
  }
  return value;
}

function fraction(name, fallback) {
  const value = positiveNumber(name, fallback);
  if (value >= 1) {
    throw new Error(`${name} must be less than one`);
  }
  return value;
}

function durationMilliseconds(name, value) {
  const match = /^(\d+(?:\.\d+)?)(ms|s|m|h)$/.exec(value);
  if (!match) {
    throw new Error(`${name} must be one positive duration such as 30s, 2m, or 1h`);
  }
  const amount = Number(match[1]);
  const factors = { ms: 1, s: 1000, m: 60000, h: 3600000 };
  if (amount <= 0) {
    throw new Error(`${name} must be greater than zero`);
  }
  return amount * factors[match[2]];
}

function currentPhase() {
  if (profile !== 'confirmation') {
    return exec.scenario.name;
  }
  const elapsed = Date.now() - exec.scenario.startTime;
  if (elapsed < lowDurationMS) {
    return 'low';
  }
  if (elapsed < lowDurationMS + rampDurationMS) {
    return 'ramp';
  }
  return 'hold';
}

function summaryLine(data, path) {
  const measuredPhase = profile === 'confirmation' ? 'hold' : profile;
  const requests = metricValue(data, `http_reqs{phase:${measuredPhase}}`, 'count');
  const observedRate = metricValue(data, `http_reqs{phase:${measuredPhase}}`, 'rate');
  const droppedMetric = profile === 'confirmation'
    ? 'dropped_iterations{scenario:confirmation}'
    : `dropped_iterations{phase:${measuredPhase}}`;
  const dropped = metricValue(data, droppedMetric, 'count');
  const accepted = metricValue(data, `accepted_events{phase:${measuredPhase}}`, 'count');
  const acceptedTotal = metricValue(data, 'accepted_events', 'count');
  const measuredDurationMS = profile === 'confirmation' ? holdDurationMS
    : profile === 'discovery' ? discoveryDurationMS
      : null;
  const attemptedRPS = measuredDurationMS !== null && typeof requests === 'number'
    ? requests / (measuredDurationMS / 1000)
    : observedRate;
  const acceptedRPS = measuredDurationMS !== null && typeof accepted === 'number'
    ? accepted / (measuredDurationMS / 1000)
    : 'n/a';
  return `run=${runID} profile=${profile} measured_phase=${measuredPhase} requests=${requests} accepted=${accepted} accepted_total=${acceptedTotal} attempted_rps=${attemptedRPS} accepted_rps=${acceptedRPS} dropped=${dropped}\nsummary=${path}\n`;
}

function metricValue(data, metric, field) {
  if (!data.metrics[metric] || data.metrics[metric].values[field] === undefined) {
    return 'n/a';
  }
  return data.metrics[metric].values[field];
}
