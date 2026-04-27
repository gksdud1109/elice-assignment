#!/usr/bin/env python3
"""Prometheus alert + metric 스냅샷을 JSON으로 박제.

incident timeline의 각 phase에서 호출되어 alert state와 핵심 SLI/diagnostic
메트릭 값을 한 번에 캡처한다. 본 자동화의 산출물은 사람이 화면을 캡처하지
않더라도 평가자가 동일한 결과를 재현/검증할 수 있게 한다.

usage:
  python3 scripts/collect-evidence.py <prometheus_url> <phase_label>
"""
import json
import sys
import time
import urllib.parse
import urllib.request

if len(sys.argv) != 3:
    print("usage: collect-evidence.py <prom_url> <phase_label>", file=sys.stderr)
    sys.exit(2)

PROM = sys.argv[1].rstrip("/")
PHASE = sys.argv[2]

# Dashboard 패널과 동일한 PromQL — evidence가 dashboard와 같은 이야기를 한다.
QUERIES = {
    "scrape_status":     'up{job="api"}',
    "request_rate_1m":   'sum by(status) (rate(http_requests_total{route=~"/api/v1/.*"}[1m]))',
    "error_rate_2m":     '(sum(rate(http_requests_total{route=~"/api/v1/.*",status=~"5.."}[2m])) or vector(0)) / sum(rate(http_requests_total{route=~"/api/v1/.*"}[2m]))',
    "availability_1h":   '1 - ((sum(increase(http_requests_total{route=~"/api/v1/.*",status=~"5.."}[1h])) or vector(0)) / sum(increase(http_requests_total{route=~"/api/v1/.*"}[1h])))',
    "latency_p95_2m":    'histogram_quantile(0.95, sum by(le) (rate(http_request_duration_seconds_bucket{route=~"/api/v1/.*"}[2m])))',
    "db_errors_5m":      'sum by(operation) (rate(db_errors_total[5m]))',
    "db_latency_p95_5m": 'histogram_quantile(0.95, sum by(operation, le) (rate(db_query_duration_seconds_bucket[5m]))) > 0',
    "fault_mode_active": 'api_fault_mode{mode!="normal"} == 1',
}


def get(path):
    with urllib.request.urlopen(f"{PROM}{path}") as r:
        return json.load(r)


def query(promql):
    return get("/api/v1/query?" + urllib.parse.urlencode({"query": promql}))["data"]["result"]


def alerts():
    return get("/api/v1/alerts")["data"]["alerts"]


def fmt_metric(result):
    if not result:
        return None
    return [
        {
            "labels": {k: v for k, v in r["metric"].items() if k != "__name__"},
            "value": r["value"][1],
        }
        for r in result
    ]


snapshot = {
    "phase": PHASE,
    "timestamp": time.strftime("%Y-%m-%d %H:%M:%S %z").strip(),
    "alerts": [
        {
            "name": a["labels"]["alertname"],
            "state": a["state"],
            "severity": a["labels"].get("severity"),
            "active_since": a.get("activeAt", ""),
            "value": a.get("value", ""),
            "annotations_summary": a.get("annotations", {}).get("summary", ""),
        }
        for a in alerts()
    ],
    "metrics": {name: fmt_metric(query(q)) for name, q in QUERIES.items()},
}

print(json.dumps(snapshot, indent=2, ensure_ascii=False))
