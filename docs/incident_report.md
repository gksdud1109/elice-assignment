# Incident Report

본 문서는 SRE 미니 프로젝트에서 실행한 장애 시나리오와 RCA를 정리한다.
메인 incident는 **Postgres 중지로 인한 user-facing 5xx 증가**이며, 보조
시나리오로 **애플리케이션 지연 장애**를 함께 검증했다.

증거 데이터는 `evidence/`의 JSON과 `timeline.txt`에서 인용했다.

---

## 1. Incident Summary

| 항목 | 내용 |
|---|---|
| Incident | Postgres outage |
| Trigger | `docker stop sre-postgres` |
| Main alert | `HighErrorRate` (critical) |
| 동반 신호 | `HighLatencyP95` (warning), `db_errors_total` 증가, `/readyz` 503 |
| 사용자 영향 | `/api/v1/*` 요청이 5xx로 실패 |
| 복구 | `docker start sre-postgres` 후 pool reconnect, alert resolved |

Postgres를 중지하자 API 프로세스는 살아 있었지만 사용자 API는 DB connection을
얻지 못해 500을 반환했다. `/readyz`는 503으로 전환되었으나 Docker Compose
환경에는 readiness 결과로 트래픽을 차단하는 routing 계층이 없기 때문에 사용자
요청은 그대로 인입되었다.

Postgres는 비즈니스 기능을 늘리기 위한 요소가 아니다. 실서비스에서 흔한
의존성 장애가 사용자 SLI로 전파되는 흐름을 검증하기 위한 최소 의존성이다.
ORM, migration, cache, HA 구성은 의도적으로 제외했다.

---

## 2. Impact

evidence: `evidence/db-stop/02-alert-firing.json`

| 지표 | 정상 | 장애 시점 | 영향 |
|---|---:|---:|---|
| Error Rate (2m) | 0% | **100%** | 모든 사용자 요청 실패 |
| Request Rate | 200 응답 9.98 rps | 500 응답 1.98 rps | 성공 요청 중단 |
| Latency p95 (2m) | 47.5ms | **4.85s** | PoolTimeout으로 지연 증가 |
| Availability (1h proxy) | 100% | 73.23% | incident 흔적 반영 |
| DB errors | 없음 | list/get 약 0.49 errors/s | DB 의존성 장애 확인 |

`HighErrorRate`가 메인 감지 신호다. `HighLatencyP95`도 함께 firing되었는데,
이는 DB connection pool timeout 때문에 실패 응답도 지연되어 반환되었기 때문이다.

---

## 3. Timeline

evidence: `evidence/db-stop/timeline.txt`

| 시각 | 단계 | 내용 |
|---|---|---|
| 20:48:41 | 발생 | Postgres 중지 |
| 20:51:12 | 감지 | `HighErrorRate` firing |
| 20:51:12 | 대응 시작 | Postgres 재시작 |
| 20:52:47 | 서비스 복구 | `/readyz` 200, pool reconnect |
| 20:54:33 | Alert resolved | rolling 2m window 정상화 |

| 지표 | 값 |
|---|---:|
| MTTD | 2분 31초 |
| Service MTTR | 4분 6초 |
| Alert resolution lag | 1분 46초 |

Alert가 서비스 복구보다 늦게 resolved된 것은 `rate(...[2m])` rolling window에
장애 데이터가 남아 있었기 때문이다. 따라서 복구 판단은 단일 명령 실행 여부가
아니라 alert resolved와 user-facing metric 정상화를 함께 본다.

---

## 4. Root Cause

**Root Cause**: 단일 Postgres 의존성의 unavailability.

### 5 Whys

| Why | 답 |
|---|---|
| 사용자가 왜 5xx를 받았나? | `/api/v1/*` 핸들러가 DB 조회 실패로 500 반환 |
| DB 조회가 왜 실패했나? | psycopg pool에서 connection 획득 실패 |
| connection 획득이 왜 실패했나? | Postgres 컨테이너가 중지되어 connection을 받을 수 없음 |
| API는 왜 트래픽을 계속 받았나? | Compose 환경에는 readiness 기반 traffic shedding이 없음 |
| 왜 사용자 영향이 100%였나? | API/Postgres 모두 단일 인스턴스라 우회 경로가 없음 |

Root cause만으로는 사용자 영향 전파를 설명하기 부족하다. 실제 운영 관점에서는
아래 contributing factors가 더 중요하다.

---

## 5. Contributing Factors

| Factor | 설명 | 영향 |
|---|---|---|
| Readiness routing 부재 | `/readyz`는 503을 반환했지만 Compose는 트래픽을 차단하지 않음 | 사용자 요청이 계속 API로 인입 |
| `depends_on`의 한계 | `service_healthy`는 startup ordering만 보장 | 운영 중 DB 장애를 해결하지 못함 |
| 단일 인스턴스 | API와 DB 모두 redundancy 없음 | 장애 영향 100% |
| Rolling window | 2분 window가 장애 데이터를 보존 | 실제 복구 후에도 alert가 잠시 firing 유지 |

Kubernetes 환경이라면 readiness probe 실패가 endpoint 제거로 이어져 사용자 영향이
줄어들 수 있다. 본 프로젝트는 이 차이를 한계로 명시하고, RCA에서 재발 방지
대책으로 다룬다.

---

## 6. Response And Recovery

### 확인

```bash
curl -i http://localhost:8000/readyz
docker compose exec postgres pg_isready -U elice -d elice
curl -fsS http://localhost:9090/api/v1/alerts
```

### 복구

```bash
docker start sre-postgres
```

### 복구 기준

- `HighErrorRate`와 `HighLatencyP95` resolved
- Error Rate < 1%
- Latency p95 < 300ms
- `/readyz` 200
- DB error rate 감소 추세

evidence: `evidence/db-stop/04-alert-resolved.json`

복구 시점에는 alert가 resolved되고 p95 latency가 48ms 수준으로 회복되었다.
다만 `db_errors_5m`은 5분 rolling window 특성상 잠시 non-zero로 남을 수 있다.
이는 신규 장애가 아니라 과거 장애 데이터의 잔여값이다.

---

## 7. Prevention

| 계층 | 대책 | 우선순위 |
|---|---|---|
| 코드 | DB `connect_timeout`, `statement_timeout`, pool acquire timeout을 latency budget에 맞춰 명시 | P1 |
| 코드 | retry/backoff 적용 시 retry storm 방지 정책 추가 | P2 |
| 운영 | runbook에 DB 의존성 확인 절차와 복구 기준 유지 | P1 |
| 운영 | error budget burn rate 기반 escalation 정책 도입 | P2 |
| 플랫폼 | Kubernetes readiness probe 또는 LB health check로 traffic shedding 구성 | P0 |
| 플랫폼 | Postgres HA 또는 managed DB failover 검토 | P1 |
| 관측 | 구조화 로그와 trace를 추가해 metric 이후 원인 추적 연결 | P2 |

본 과제에서는 Alertmanager, HA, tracing/logging까지 구현하지 않았다. 과제 목적은
복잡한 인프라 구성보다 정상/장애 기준 정의와 검증이므로, 확장 방향으로만 남겼다.

---

## 8. What Went Well

- 사용자 영향 기반 alert가 먼저 동작했다. DB 자체 alert 없이도 사용자가 실패를
  보고 있음을 `HighErrorRate`로 감지했다.
- DB diagnostic metric이 원인 범위를 빠르게 좁혔다.
- `/readyz`가 DB 장애를 정확히 반영했다.
- 복구 판단을 alert resolved와 metric 정상화로 정의해 rolling window 지연을
  자연스럽게 설명할 수 있었다.

---

## Appendix. Latency Incident

보조 시나리오는 `fault-mode slow`로 애플리케이션 지연만 주입했다.

| 항목 | 내용 |
|---|---|
| Trigger | `POST /admin/fault-mode {"mode":"slow","delay_ms":700}` |
| Alert | `HighLatencyP95` |
| Error Rate | 0% 유지 |
| p95 latency | 975ms |
| 복구 | `fault-mode normal` |

Timeline:

| 시각 | 단계 | 내용 |
|---|---|---|
| 20:56:14 | 발생 | slow 700ms 주입 |
| 20:58:45 | 감지 | `HighLatencyP95` firing |
| 20:58:45 | 대응 | normal 모드 복귀 |
| 21:00:46 | 복구 | alert resolved |

DB stop과 달리 Error Rate는 0%로 유지되었고, DB error도 증가하지 않았다. 이
차이는 dashboard에서 dependency 장애와 application latency 장애를 구분할 수
있음을 보여준다.

---

## Evidence Map

| 파일 | 의미 |
|---|---|
| `evidence/db-stop/01-baseline.json` | 정상 상태 |
| `evidence/db-stop/02-alert-firing.json` | DB down, `HighErrorRate` firing |
| `evidence/db-stop/03-service-recovered.json` | `/readyz` 200, alert는 rolling window로 firing 유지 |
| `evidence/db-stop/04-alert-resolved.json` | alert resolved |
| `evidence/latency/02-alert-firing.json` | latency fault, `HighLatencyP95` firing |

