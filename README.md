# Elice SRE Mini Project

강의 카탈로그 API를 대상으로 SLI/SLO, Alert, Dashboard, Incident Response를
재현 가능하게 구성한 SRE 미니 프로젝트입니다.

핵심 설계:

- SLI는 사용자 API(`/api/v1/*`)만 집계합니다. probe, metrics, admin 요청은 제외합니다.
- Postgres 1개를 최소 의존성으로 두어 dependency failure가 사용자 SLI로 전파되는 흐름을 검증합니다.
- Paging 기준은 user-facing symptom입니다. DB 메트릭은 RCA 보조 신호로만 사용합니다.
- Prometheus rule과 Grafana dashboard는 모두 코드로 provisioning됩니다.

문서:

- 설계 문서: [docs/sli_slo_design.md](docs/sli_slo_design.md)
- Incident evidence: [evidence/README.md](evidence/README.md)

## Quick Start

```bash
# API, Postgres, Prometheus, Grafana
docker compose up -d --build

# baseline traffic 포함
docker compose --profile load up -d --build
```

기동 확인:

```bash
curl -fsS http://localhost:8000/healthz
curl -fsS http://localhost:8000/readyz
curl -fsS http://localhost:8000/api/v1/courses
```

접속 URL:

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

| Method | Path | SLI 집계 | 목적 |
|---|---|---|---|
| GET | `/healthz` | 제외 | liveness |
| GET | `/readyz` | 제외 | DB readiness (`SELECT 1`) |
| GET | `/api/v1/courses` | 포함 | 사용자 API |
| GET | `/api/v1/courses/{id}` | 포함 | 사용자 API |
| POST | `/admin/fault-mode` | 제외 | 장애 주입 |
| GET | `/metrics` | 제외 | Prometheus scrape |

## Incident Reproduction

사전 조건:

```bash
docker compose --profile load up -d --build
```

### Scenario 1. Postgres 중지

의도: DB 의존성 장애가 사용자 5xx와 `HighErrorRate`로 전파되는지 검증합니다.
DB timeout 영향으로 `HighLatencyP95`가 함께 firing될 수 있습니다.

```bash
bash scripts/incident-db-stop.sh
```

### Scenario 2. Latency fault

의도: 5xx 없이 p95 latency만 악화되는 상황에서 `HighLatencyP95`가 firing되는지
검증합니다.

```bash
bash scripts/incident-latency.sh
```

각 스크립트는 장애 주입, alert firing 대기, 복구, resolved 대기를 수행하고
`evidence/<scenario>/`에 JSON evidence와 timeline을 저장합니다.

복구 기준:

- alert resolved
- Error Rate 정상화
- p95 Latency 300ms 이하
- DB incident의 경우 `/readyz` 200, DB error 증가 중단

## Incident Response

Alert rule의 `runbook` annotation은 아래 anchor를 가리킵니다.

### runbook-APIInstanceDown

의미: Prometheus가 API 인스턴스를 1분 이상 scrape하지 못했습니다.

확인:

```bash
docker compose ps
docker compose logs --tail=50 api
curl -i http://localhost:8000/healthz
```

대응:

- API 컨테이너가 stopped/exited 상태면 `docker compose up -d api`로 재기동합니다.
- `/healthz`는 200이지만 scrape가 실패하면 compose network 또는 service DNS를 확인합니다.

복구 기준:

- `up{job="api"} == 1`
- alert resolved
- `/healthz` 200

### runbook-HighErrorRate

의미: 사용자 API 5xx 비율이 2분간 5%를 초과했습니다.

확인:

```bash
curl -fsS 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=sum by(route,status) (rate(http_requests_total{route=~"/api/v1/.*",status=~"5.."}[2m]))'

curl -i http://localhost:8000/readyz
docker compose exec postgres pg_isready -U elice -d elice
curl -fsS http://localhost:8000/metrics | grep '^api_fault_mode'
```

대응:

- DB가 down/unreachable 상태면 `docker compose up -d postgres` 후 `/readyz` 200을 확인합니다.
- fault mode가 `error` 또는 `flaky`이면 `normal`로 되돌립니다.
- 그 외에는 최근 애플리케이션 변경이나 배포를 확인합니다.

복구 기준:

- error rate < 1%
- alert resolved
- DB incident의 경우 `db_errors_total` 증가 중단

### runbook-HighLatencyP95

의미: 사용자 API p95 응답 시간이 2분간 500ms를 초과했습니다.

확인:

```bash
curl -fsS http://localhost:8000/metrics | grep '^api_fault_mode'

curl -fsS 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=histogram_quantile(0.95, sum by(operation,le) (rate(db_query_duration_seconds_bucket[5m])))'
```

대응:

- fault mode가 `slow`이면 `normal`로 되돌립니다.
- DB query latency가 함께 상승하면 DB 부하, lock, connection 상태를 확인합니다.
- 애플리케이션 지연만 상승하면 최근 코드 변경의 blocking 작업을 확인합니다.

복구 기준:

- p95 latency < 300ms
- alert resolved

## Directory

```text
api/                 FastAPI service
db/                  Postgres seed SQL
prometheus/          scrape config, alert rules
grafana/             datasource/dashboard provisioning
k6/                  baseline traffic
scripts/             incident automation
evidence/            captured alert/metric evidence
docs/                design and incident documents
docker-compose.yml
```

## Limitations

- 단일 인스턴스, in-memory fault state
- Docker Compose 환경의 readiness routing 부재
- Alertmanager 미통합
- Prometheus 장기 보관 미구성
- 구조화 로그와 분산 추적 미구성
- `/admin/fault-mode` 인증 없음
