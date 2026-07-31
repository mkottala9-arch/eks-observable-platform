import http from 'k6/http';
import { check } from 'k6';

export const options = {
  vus: 3,
  duration: '15m',
};

export default function () {
  const res = http.get('http://podinfo.manual-managed.svc.cluster.local:9898/');
  check(res, { 'status is 200': (r) => r.status === 200 });
}