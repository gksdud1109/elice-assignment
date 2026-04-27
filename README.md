# Elice SRE Mini Project

강의 카탈로그 API를 대상으로 SLI/SLO, Alert, Dashboard, Incident Response를
재현하는 미니 프로젝트입니다.

핵심 결정:

- 사용자 API(`/api/v1/*`)만 SLI에 포함합니다.
- `/healthz`, `/readyz`, `/metrics`, `/admin/*`는 SLI에서 제외합니다.
- Postgres 1개로 의존성 장애가 사용자 지표로 전파되는 흐름을 검증합니다.
- Alert는 DB 자체가 아니라 Error Rate, Latency 같은 사용자 증상 기준으로 둡니다.
- Prometheus rule과 Grafana dashboard는 코드로 provisioning됩니다.

문서:

- [SLI/SLO 설계](docs/sli_slo_design.md) ([PDF](docs/sli_slo_design.pdf))
- [Incident Report](docs/incident_report.md) ([PDF](docs/incident_report.pdf))
- [Evidence 설명](evidence/README.md)

## Quick Start

```bash
docker compose up -d --build
docker compose --profile load up -d --build
```

확인:

```bash
curl -fsS http://localhost:8000/healthz
curl -fsS http://localhost:8000/readyz
curl -fsS http://localhost:8000/api/v1/courses
```

| 서비스 | URL | 비고 |
|---|---|---|
| API | http://localhost:8000 | FastAPI |
| Prometheus | http://localhost:9090 | targets, alerts, query |
| Grafana | http://localhost:3000 | `admin/admin`, dashboard 자동 등록 |

종료:

```bash
docker compose --profile load down -v
```

## API

| Method | Path | SLI | 목적 |
|:--|:--|:--|:--|
| GET | `/healthz` | 제외 | liveness |
| GET | `/readyz` | 제외 | DB readiness |
| GET | `/api/v1/courses` | 포함 | 사용자 API |
| GET | `/api/v1/courses/{id}` | 포함 | 사용자 API |
| POST | `/admin/fault-mode` | 제외 | 장애 주입 |
| GET | `/metrics` | 제외 | Prometheus scrape |

> 장애 주입은 `scripts`에 구성되어있는 incident 스크립트에서 모두 자동화 되어있습니다.</br>

직접 확인용 장애 주입 예시:

```bash
# 700ms 지연 주입
curl -fsS -X POST http://localhost:8000/admin/fault-mode \
  -H 'Content-Type: application/json' \
  -d '{"mode":"slow","delay_ms":700}'

# 5xx 오류 주입
curl -fsS -X POST http://localhost:8000/admin/fault-mode \
  -H 'Content-Type: application/json' \
  -d '{"mode":"error"}'

# 간헐적 5xx 오류 주입 (30%)
curl -fsS -X POST http://localhost:8000/admin/fault-mode \
  -H 'Content-Type: application/json' \
  -d '{"mode":"flaky","error_rate":0.3}'

# 정상 복구
curl -fsS -X POST http://localhost:8000/admin/fault-mode \
  -H 'Content-Type: application/json' \
  -d '{"mode":"normal"}'
```

## Incident Reproduction

사전 조건:

```bash
docker compose --profile load up -d --build
```

메인 시나리오: Postgres 중지

```bash
bash scripts/incident-db-stop.sh
```

의도: DB 장애가 사용자 5xx, `HighErrorRate`, DB diagnostic metric으로 전파되는지
검증합니다. 스크립트는 시작 시 `fault-mode=normal`로 초기화해 애플리케이션
장애 주입과 DB 장애를 분리합니다. DB timeout 영향으로 `HighLatencyP95`가 함께
firing될 수 있습니다.

보조 시나리오: latency fault

```bash
bash scripts/incident-latency.sh
```

의도: 5xx 없이 p95 latency만 악화되는 경우 `HighLatencyP95`가 firing되는지
검증합니다. 이 시나리오는 application fault-mode만 사용하며 DB는 정상 상태로
둡니다.

각 스크립트는 `evidence/<scenario>/`에 JSON evidence와 timeline을 저장합니다.

복구 기준:

- alert resolved
- Error Rate 정상화
- p95 Latency 300ms 이하
- DB incident는 `/readyz` 200, DB error 증가 중단

## Runbook

Alert rule의 `runbook` annotation은 아래 anchor를 가리킵니다.

### runbook-APIInstanceDown

의미: Prometheus가 API를 1분 이상 scrape하지 못했습니다.

```bash
docker compose ps
docker compose logs --tail=50 api
curl -i http://localhost:8000/healthz
```

복구 기준: `up{job="api"} == 1`, alert resolved, `/healthz` 200.

### runbook-HighErrorRate

의미: 사용자 API 5xx 비율이 2분간 5%를 초과했습니다.

```bash
curl -fsS 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=sum by(route,status) (rate(http_requests_total{route=~"/api/v1/.*",status=~"5.."}[2m]))'

curl -i http://localhost:8000/readyz
docker compose exec postgres pg_isready -U elice -d elice
curl -fsS http://localhost:8000/metrics | grep '^api_fault_mode'
```

대응: DB 상태를 먼저 확인하고, fault mode가 `error` 또는 `flaky`이면 `normal`로
되돌립니다.

복구 기준: error rate < 1%, alert resolved.

### runbook-HighLatencyP95

의미: 사용자 API p95 응답 시간이 2분간 500ms를 초과했습니다.

```bash
curl -fsS http://localhost:8000/metrics | grep '^api_fault_mode'

curl -fsS 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=histogram_quantile(0.95, sum by(operation,le) (rate(db_query_duration_seconds_bucket[5m])))'
```

대응: fault mode가 `slow`이면 `normal`로 되돌립니다. DB query latency도 함께
상승하면 DB 상태를 확인합니다.

복구 기준: p95 latency < 300ms, alert resolved.

## Directory

```text
api/                 FastAPI service
db/                  Postgres seed SQL
prometheus/          scrape config, alert rules
grafana/             datasource/dashboard provisioning
k6/                  baseline traffic
scripts/             incident automation
evidence/            alert/metric evidence
docs/                design and incident documents
docker-compose.yml
```

## Limitations

- 단일 인스턴스
- Docker Compose readiness routing 부재
- Alertmanager 미통합
- Prometheus 장기 보관 미구성
- 구조화 로그와 분산 추적 미구성
- `/admin/fault-mode` 인증 없음
