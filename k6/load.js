import http from 'k6/http';
import { check } from 'k6';

const TARGET = __ENV.TARGET;

export const options = {
  // ramp up, hold, ramp down. more realistic than a fixed VU count -
  // it exercises the app under changing concurrency rather than a
  // constant one.
  stages: [
    { duration: '30s', target: 10 },   // ramp to 10 users
    { duration: '2m',  target: 10 },   // hold
    { duration: '30s', target: 0 },    // ramp down
  ],

  thresholds: {
    // looser than smoke on purpose. under sustained load, tolerating a
    // small failure rate is realistic - a single transient blip during a
    // rolling update shouldn't fail a promotion. 1% is still tight enough
    // that FAULT_MODE=true (which fails ~100%) trips it immediately.
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<1000'],
  },
};

export default function () {
  const res = http.get(`${TARGET}/`);
  check(res, { 'status is 200': (r) => r.status === 200 });
}