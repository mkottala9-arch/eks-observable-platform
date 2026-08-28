import http from 'k6/http';
import { check } from 'k6';

// injected by the Job, so the same script works for app-dev and app-prod
const TARGET = __ENV.TARGET;

export const options = {
  vus: 5,
  duration: '20s',

  // thresholds make this a GATE. if one fails, k6 exits non-zero
  // and the pipeline step fails. check() alone would not do this.
  thresholds: {
    http_req_failed: ['rate==0'],      // zero failed requests tolerated
    http_req_duration: ['p(95)<500'],  // 95% under 500ms
  },
};

export default function () {
  const res = http.get(`${TARGET}/`);

  // records a result for readable output. does NOT affect the exit code.
  check(res, {
    'status is 200': (r) => r.status === 200,
  });
}