import http from "k6/http";
import { sleep } from "k6";

// 사용자 API에 일정 RPS의 baseline 트래픽을 흘려 dashboard/alert이 의미
// 있는 데이터를 받게 한다. 부하 자체가 SLO를 침범하지 않도록 가벼운 수준.
// Phase 5 incident 시나리오는 별도 스크립트가 이어받는다.

export const options = {
  scenarios: {
    constant_load: {
      executor: "constant-vus",
      vus: 5,
      duration: "24h",
    },
  },
  thresholds: {
    // baseline에서는 어떤 thresholds도 fail로 처리하지 않는다.
    // 실제 SLO 검증은 Prometheus alert가 담당.
  },
};

const BASE = __ENV.K6_API_BASE || "http://api:8000";

export default function () {
  http.get(`${BASE}/api/v1/courses`);
  http.get(`${BASE}/api/v1/courses/1`);
  sleep(1);
}
