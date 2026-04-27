# Incident Report

본 문서는 SRE 미니 프로젝트의 장애 시나리오와 RCA를 정리합니다.

메인 incident는 **Postgres 중지로 인한 사용자 API 5xx 증가**입니다. 보조
시나리오로 **애플리케이션 지연 장애**도 함께 검증했습니다.

---

## 1. 장애 요약

| 항목 | 내용 |
|:--|:--|
| Incident | Postgres outage |
| Trigger | `fault-mode=normal`에서 `docker stop sre-postgres` |
| Main alert | `HighErrorRate` (critical) |
| 동반 신호 | `HighLatencyP95`, `db_errors_total`, `/readyz` 503 |
| 사용자 영향 | `/api/v1/*` 요청이 5xx로 실패 |
| 복구 | `docker start sre-postgres` 후 pool reconnect |

스크립트는 먼저 `fault-mode=normal`로 초기화한 뒤 Postgres를 중지합니다.
따라서 이 incident의 5xx 원인은 애플리케이션 fault-mode가 아니라 DB 의존성
장애입니다. API 프로세스는 살아 있었지만 사용자 API는 DB connection을 얻지
못해 500을 반환했습니다. `/readyz`는 503으로 전환되었지만 Docker Compose에는 이를
트래픽 차단으로 연결하는 routing 계층이 없습니다.

Postgres는 비즈니스 기능을 늘리기 위한 요소가 아닙니다. 의존성 장애가 사용자
SLI로 전파되는 흐름을 검증하기 위한 최소 구성입니다.

---

## 2. 영향 범위

evidence: `evidence/db-stop/02-alert-firing.json`

| 지표 | 정상 | 장애 시점 |
|:--|:--|:--|
| Error Rate (2m) | 0% | **100%** |
| Request Rate | 200 응답 9.98 rps | 500 응답 1.98 rps |
| Latency p95 (2m) | 47.5ms | **4.85s** |
| Availability (1h proxy) | 100% | 73.23% |
| DB errors | 없음 | list/get 약 0.49 errors/s |

`HighErrorRate`가 메인 감지 신호입니다. `HighLatencyP95`도 함께 firing되었는데,
DB connection pool timeout 때문에 실패 응답도 지연되어 반환되었기 때문입니다.

---

## 3. 타임라인

evidence: `evidence/db-stop/timeline.txt`

| 시각 | 단계 | 내용 |
|:--|:--|:--|
| 20:48:41 | 발생 | Postgres 중지 |
| 20:51:12 | 감지 | `HighErrorRate` firing |
| 20:51:12 | 대응 시작 | Postgres 재시작 |
| 20:52:47 | 서비스 복구 | `/readyz` 200, pool reconnect |
| 20:54:33 | Alert resolved | rolling 2m window 정상화 |

| 지표 | 값 |
|:--|:--|
| MTTD | 2분 31초 |
| Service MTTR | 4분 6초 |
| Alert resolution lag | 1분 46초 |

Alert가 서비스 복구보다 늦게 resolved된 이유는 2분 rolling window에 장애 데이터가
남아 있었기 때문입니다. 복구는 명령 실행이 아니라 alert와 metric 회복으로
판단합니다.

---

## 4. Root Cause

**Root Cause**: 단일 Postgres 의존성의 unavailability.

| Why | 답 |
|:--|:--|
| 사용자가 왜 5xx를 받았나? | 사용자 API가 DB 조회 실패로 500 반환 |
| DB 조회가 왜 실패했나? | psycopg pool에서 connection 획득 실패 |
| connection 획득이 왜 실패했나? | Postgres 컨테이너가 중지됨 |
| API는 왜 트래픽을 계속 받았나? | Compose에는 readiness 기반 traffic shedding이 없음 |
| 왜 영향이 100%였나? | API와 DB가 모두 단일 인스턴스 |

Root cause는 DB 중지이지만, 사용자 영향으로 번진 이유는 아래 contributing
factors가 설명합니다.

---

## 5. Contributing Factors

| Factor | 영향 |
|:--|:--|
| Readiness routing 부재 | `/readyz` 503에도 사용자 요청이 계속 인입 |
| `depends_on`의 한계 | startup ordering만 보장, 운영 중 장애는 해결하지 못함 |
| 단일 인스턴스 | 우회 경로가 없어 영향이 100%로 확대 |
| Rolling window | 실제 복구 후에도 alert가 잠시 firing 유지 |

Kubernetes 환경이라면 readiness probe 실패가 endpoint 제거로 이어져 사용자 영향을
줄일 수 있습니다. 본 프로젝트는 이 차이를 한계와 재발 방지 대책으로 다룹니다.

---

## 6. 대응 및 복구

확인:

```bash
curl -i http://localhost:8000/readyz
docker compose exec postgres pg_isready -U elice -d elice
curl -fsS http://localhost:9090/api/v1/alerts
```

복구:

```bash
docker start sre-postgres
```

복구 기준:

- `HighErrorRate`, `HighLatencyP95` resolved
- Error Rate < 1%
- Latency p95 < 300ms
- `/readyz` 200
- DB error rate 감소 추세

`evidence/db-stop/04-alert-resolved.json` 기준으로 alert는 resolved되고 p95 latency는
48ms 수준으로 회복되었습니다. `db_errors_5m`은 5분 window 때문에 잠시 non-zero로
남을 수 있습니다.

---

## 7. 재발 방지 대책

| 계층 | 대책 |
|:--|:--|
| 코드 | DB `connect_timeout`, `statement_timeout`, pool acquire timeout을 latency budget에 맞춰 명시 |
| 코드 | retry/backoff 적용 시 retry storm 방지 |
| 운영 | runbook에 DB 의존성 확인 절차와 복구 기준 유지 |
| 운영 | error budget burn rate 기반 escalation 정책 도입 |
| 플랫폼 | readiness probe 또는 LB health check로 traffic shedding 구성 |
| 플랫폼 | Postgres HA 또는 managed DB failover 검토 |
| 관측 | 구조화 로그와 trace를 추가해 metric 이후 원인 추적 연결 |

본 과제에서는 Alertmanager, HA, tracing/logging까지 구현하지 않았습니다. 과제
목적은 복잡한 인프라 구성이 아니라 정상/장애 기준 정의와 검증이기 때문입니다.

---

## 8. 잘 동작한 부분

- 사용자 영향 기반 alert가 먼저 동작했습니다.
- DB diagnostic metric이 원인 범위를 빠르게 좁혔습니다.
- `/readyz`가 DB 장애를 정확히 반영했습니다.
- 복구 기준을 metric 기반으로 둔 덕분에 rolling window 지연을 설명할 수 있었습니다.

---

## Appendix. Latency Incident

보조 시나리오는 `fault-mode slow`로 애플리케이션 지연만 주입했습니다.

| 항목 | 내용 |
|:--|:--|
| Trigger | `POST /admin/fault-mode {"mode":"slow","delay_ms":700}` |
| Alert | `HighLatencyP95` |
| Error Rate | 0% 유지 |
| p95 latency | 975ms |
| 복구 | `fault-mode normal` |

| 시각 | 단계 | 내용 |
|:--|:--|:--|
| 20:56:14 | 발생 | slow 700ms 주입 |
| 20:58:45 | 감지 | `HighLatencyP95` firing |
| 20:58:45 | 대응 | normal 모드 복귀 |
| 21:00:46 | 복구 | alert resolved |

DB stop과 달리 Error Rate와 DB error는 증가하지 않았습니다. 이 차이로 의존성 장애와
애플리케이션 지연 장애를 구분할 수 있습니다.

---

## Evidence Map

| 파일 | 의미 |
|:--|:--|
| `evidence/db-stop/01-baseline.json` | 정상 상태 |
| `evidence/db-stop/02-alert-firing.json` | DB down, `HighErrorRate` firing |
| `evidence/db-stop/03-service-recovered.json` | `/readyz` 200, alert는 rolling window로 firing 유지 |
| `evidence/db-stop/04-alert-resolved.json` | alert resolved |
| `evidence/latency/02-alert-firing.json` | latency fault, `HighLatencyP95` firing |
