# Elice SRE Mini Project

간단한 강의 카탈로그 API를 대상으로 신뢰성을 정의하고 검증하는 미니 프로젝트입니다.
사용자 API의 성공률, 오류율, 지연 시간을 SLI/SLO로 정의하고, Postgres 의존성 장애가
사용자 관점 지표로 전파되는 흐름을 Prometheus와 Grafana로 확인합니다.

- 설계 문서: [docs/sli_slo_design.md](docs/sli_slo_design.md)

## 빠른 시작

```bash
# API, Postgres, Prometheus, Grafana 실행
docker compose up -d --build

# baseline 트래픽까지 함께 실행
docker compose --profile load up -d --build
```

기동 확인:

```bash
curl -fsS http://localhost:8000/healthz
curl -fsS http://localhost:8000/readyz
curl -fsS http://localhost:8000/api/v1/courses
```

종료 및 데이터 정리:

```bash
docker compose --profile load down -v
```

## 접속 URL

| 서비스 | URL | 비고 |
|---|---|---|
| API | http://localhost:8000 | FastAPI service |
| Prometheus | http://localhost:9090 | targets, alerts, query |
| Grafana | http://localhost:3000 | `admin/admin`, dashboard `SRE - API Overview` 자동 등록 |

## API

| Method | Path | SLI 집계 | 비고 |
|---|---|---|---|
| GET | `/healthz` | 제외 | liveness, 프로세스 생존 확인 |
| GET | `/readyz` | 제외 | readiness, DB `SELECT 1` 확인 |
| GET | `/api/v1/courses` | 포함 | 사용자 API, DB 조회 |
| GET | `/api/v1/courses/{id}` | 포함 | 사용자 API, DB 조회 |
| POST | `/admin/fault-mode` | 제외 | 장애 주입 모드 변경 |
| GET | `/metrics` | 제외 | Prometheus metrics |

SLI는 사용자 API인 `/api/v1/*`만 집계합니다. `/healthz`, `/readyz`, `/metrics`,
`/admin/*`는 사용자 경험을 직접 나타내지 않으므로 제외합니다.

## 장애 재현

### 시나리오 1: Postgres 중지 → HighErrorRate

```bash
# baseline 트래픽 시작
docker compose --profile load up -d

# Prometheus가 baseline 데이터를 수집할 시간을 둠
sleep 300

# Postgres 중지
docker stop sre-postgres

# 약 2분 후 alert 상태 확인
curl -fsS http://localhost:9090/api/v1/alerts

# 복구
docker start sre-postgres

# readiness 복구 확인
curl -fsS http://localhost:8000/readyz
```

### 시나리오 2: fault-mode slow → HighLatencyP95

```bash
# baseline 트래픽 시작
docker compose --profile load up -d

# 700ms 지연 주입
curl -fsS -X POST http://localhost:8000/admin/fault-mode \
  -H 'Content-Type: application/json' \
  -d '{"mode":"slow","delay_ms":700}'

# 약 2분 후 alert 상태 확인
curl -fsS http://localhost:9090/api/v1/alerts

# 복구
curl -fsS -X POST http://localhost:8000/admin/fault-mode \
  -H 'Content-Type: application/json' \
  -d '{"mode":"normal"}'
```

### 복구 기준

복구는 명령 실행 여부가 아니라 메트릭 정상화로 판정합니다.

- Prometheus alert가 resolved 상태로 전환
- Error rate가 1% 미만으로 복귀
- p95 latency가 300ms 미만으로 복귀
- DB 의존성 신호 정상화 (`/readyz` 200, `db_errors_total` 증가 중단)

## Incident Response

각 alert의 `runbook` annotation은 아래 절을 가리킵니다.

### runbook-APIInstanceDown

**의미**: Prometheus가 API 인스턴스를 1분 이상 scrape 하지 못했습니다.

확인:

```bash
docker compose ps
docker compose logs --tail=50 api
curl -i http://localhost:8000/healthz
```

대응:

- API 컨테이너가 stopped/exited 상태면 `docker compose up -d api`로 재기동합니다.
- `/healthz`는 200이지만 scrape가 실패하면 compose network 또는 service DNS를 확인합니다.
- 반복 재기동이 발생하면 startup log와 DB connection 상태를 확인합니다.

복구 기준:

- `up{job="api"} == 1`
- alert resolved
- `/healthz` 200

### runbook-HighErrorRate

**의미**: 사용자 API 5xx 비율이 2분간 5%를 초과했습니다.

확인:

```bash
# 5xx 발생 route/status 확인
curl -fsS 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=sum by(route,status) (rate(http_requests_total{route=~"/api/v1/.*",status=~"5.."}[2m]))'

# DB 의존성 상태
curl -i http://localhost:8000/readyz
docker compose exec postgres pg_isready -U elice -d elice

# 장애 주입 모드 확인
curl -fsS http://localhost:8000/metrics | grep '^api_fault_mode'
```

대응:

- DB가 down/unreachable 상태면 `docker compose up -d postgres` 후 `/readyz` 200을 확인합니다.
- fault mode가 `error` 또는 `flaky`이면 `normal`로 되돌립니다.
- 두 조건에 해당하지 않으면 최근 애플리케이션 변경이나 배포를 확인합니다.

복구 기준:

- error rate < 1%
- alert resolved
- `db_errors_total` 증가 중단

### runbook-HighLatencyP95

**의미**: 사용자 API p95 응답 시간이 2분간 500ms를 초과했습니다.

확인:

```bash
# 장애 주입 모드 확인
curl -fsS http://localhost:8000/metrics | grep '^api_fault_mode'

# DB query latency 확인
curl -fsS 'http://localhost:9090/api/v1/query' \
  --data-urlencode 'query=histogram_quantile(0.95, sum by(operation,le) (rate(db_query_duration_seconds_bucket[2m])))'
```

대응:

- fault mode가 `slow`이면 `normal`로 되돌립니다.
- DB query latency가 함께 상승하면 DB 부하, lock, connection 상태를 확인합니다.
- 애플리케이션 지연만 상승하면 최근 코드 변경의 동기 호출이나 blocking 작업을 확인합니다.

Escalation 기준:

- 동일 상태가 30분 이상 지속
- 단일 incident에서 error budget의 25% 이상 소진
- client timeout 또는 5xx 증가가 함께 발생

복구 기준:

- p95 latency < 300ms
- alert resolved

## 디렉터리 구조

```text
elice-assignment/
├── api/
│   ├── app/
│   ├── Dockerfile
│   └── requirements.txt
├── db/
│   └── init.sql
├── prometheus/
│   ├── prometheus.yml
│   └── alert-rules.yml
├── grafana/
│   ├── provisioning/
│   └── dashboards/
├── k6/
│   └── normal.js
├── docs/
│   └── sli_slo_design.md
├── docker-compose.yml
└── README.md
```

## 한계

자세한 내용은 [docs/sli_slo_design.md §7](docs/sli_slo_design.md)을 참고합니다.

- 단일 인스턴스와 in-memory fault state
- `/admin/fault-mode` 인증 없음
- Prometheus 장기 보관 미구성
- Alertmanager 미통합
- Docker Compose 환경의 readiness routing 부재
- 단일 임계 alert 사용
- 분산 추적과 구조화 로그 미통합
- DB timeout 계층 중 connection acquire timeout만 적용
