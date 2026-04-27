# SLI / SLO 설계 문서

본 문서는 강의 카탈로그 조회 API를 대상으로 정상 상태를 정의하고, 이를
Prometheus/Grafana 기반으로 측정·검증하기 위한 설계 결정을 정리한다.

핵심 원칙은 하나다.

> 서비스 정상 여부는 프로세스 생존이 아니라 사용자 API의 성공률, 오류율,
> 지연 시간으로 판단한다.

---

## 1. 서비스와 범위

| 항목 | 내용 |
|---|---|
| 가상 서비스 | Elice 강의 카탈로그 조회 API |
| 사용자 API | `GET /api/v1/courses`, `GET /api/v1/courses/{id}` |
| 트래픽 특성 | 동기 read-heavy 조회 API |
| 의존성 | Postgres 1개 |
| 실행 환경 | Docker Compose 단일 인스턴스 |

API 서버는 비즈니스 기능이 아니라 신뢰성 검증 대상이다. 따라서 도메인 로직은
최소화하고, 정상 응답·지연·5xx·Postgres 의존성 장애를 재현할 수 있게 구성했다.

Postgres를 추가한 이유는 실제 서비스 장애가 애플리케이션 단독 문제가 아니라
의존성 장애로 전파되는 경우가 많기 때문이다. 다만 ORM, migration tool, cache,
multi-instance, Kubernetes는 과제 범위에서 제외했다.

---

## 2. 정상 상태 정의

본 프로젝트에서 정상 상태는 다음과 같이 정의한다.

> 사용자가 강의 목록 또는 상세 API를 호출했을 때, 정해진 지연 시간 안에 5xx 없이
> 응답을 받는 상태.

이 정의에 따라 probe와 사용자 요청을 분리한다.

| Endpoint | 목적 | SLI 포함 |
|---|---|---|
| `/healthz` | 프로세스 생존 확인 | 제외 |
| `/readyz` | DB 연결 가능 여부 확인 (`SELECT 1`) | 제외 |
| `/metrics` | Prometheus scrape | 제외 |
| `/admin/fault-mode` | 장애 주입 제어 | 제외 |
| `/api/v1/*` | 사용자 요청 | 포함 |

SLI 집계는 항상 사용자 API만 대상으로 한다.

```promql
{route=~"/api/v1/.*"}
```

`/healthz`가 200이어도 사용자는 5xx를 볼 수 있다. 예를 들어 API 프로세스는
살아 있지만 Postgres가 중지되면 `/healthz`는 성공하고, `/readyz`는 503이며,
사용자 API는 5xx로 실패한다. 따라서 사용자 관점의 정상성은 `/api/v1/*`의
실제 결과로 판단한다.

Docker Compose 환경에는 Kubernetes readiness probe나 LB health check가 없으므로
`/readyz` 실패가 자동 트래픽 차단으로 이어지지 않는다. 이 한계는 incident
report에서 contributing factor로 다룬다.

---

## 3. SLI / SLO

| SLI | 정의 | SLO | 역할 |
|---|---|---:|---|
| Availability | 5xx가 아닌 사용자 응답 / 전체 사용자 응답 | 30일 99.9% | 장기 신뢰도와 에러버짓 |
| Error Rate | 5xx 사용자 응답 / 전체 사용자 응답 | 5분 1% 이하 | 단기 장애 감지 |
| Latency p95 | 사용자 API 응답 시간 p95 | 5분 300ms 이하 | 사용자 체감 지연 |

### Availability와 Error Rate를 나눈 이유

두 값은 수식상 서로 연결된다. 그러나 운영 목적이 다르다.

- Availability는 30일 누적 목표다. 에러버짓과 배포 판단에 사용한다.
- Error Rate는 짧은 시간에 장애가 발생 중인지 판단하는 운영 신호다.

따라서 SLO와 alert 임계값을 동일하게 두지 않는다. SLO는 장기 목표이고, alert는
사람이 개입해야 하는 신호다.

### 대표 PromQL

```promql
# 30일 Availability
sum(increase(http_requests_total{route=~"/api/v1/.*",status!~"5.."}[30d]))
/
sum(increase(http_requests_total{route=~"/api/v1/.*"}[30d]))

# 5분 Error Rate
sum(rate(http_requests_total{route=~"/api/v1/.*",status=~"5.."}[5m]))
/
sum(rate(http_requests_total{route=~"/api/v1/.*"}[5m]))

# 5분 Latency p95
histogram_quantile(0.95,
  sum by(le) (rate(http_request_duration_seconds_bucket{route=~"/api/v1/.*"}[5m]))
)
```

데모 환경의 Prometheus 데이터는 장기 보관되지 않는다. 따라서 dashboard에서는
30일 Availability 대신 1시간 proxy를 표시하고, 운영 환경의 30일 정의는 위
PromQL로 문서화한다.

### SLO 수치 근거

| 항목 | 결정 | 근거 |
|---|---|---|
| Availability 99.9% | 채택 | 월 약 43분 장애 허용. 단일 incident와 짧은 정비를 흡수할 수 있는 현실적 목표 |
| Error Rate 1% | 채택 | 짧은 윈도우에서 사용자 실패가 관측되는 수준 |
| Latency p95 300ms | 채택 | 단순 read API에서 사용자가 느리다고 체감하기 전 관리해야 할 목표 |

4xx는 서비스 신뢰성 실패로 보지 않고 성공으로 분류한다. 인증 실패나 비정상 404
증가는 별도 운영 신호로 확장할 수 있다.

---

## 4. Metrics 설계

| 목적 | 메트릭 | 비고 |
|---|---|---|
| 요청 수 / 오류율 | `http_requests_total{method,route,status}` | 사용자 SLI의 기준 |
| 지연 시간 | `http_request_duration_seconds{method,route}` | p95 계산용 histogram |
| 장애 주입 상태 | `api_fault_mode{mode}` | Grafana annotation, RCA 타임라인 |
| DB 지연 | `db_query_duration_seconds{operation}` | RCA 보조 신호 |
| DB 오류 | `db_errors_total{operation}` | RCA 보조 신호 |

`route` 라벨은 실제 URL이 아니라 route template을 사용한다.

```text
/api/v1/courses/1  -> /api/v1/courses/{course_id}
```

이렇게 해야 course id마다 시계열이 늘어나는 cardinality 문제를 피할 수 있다.
`user_id`, `request_id`, IP 같은 고유값은 metric label에 넣지 않는다.

Latency histogram bucket은 SLO와 alert 임계 근처에 맞췄다.

```python
(0.05, 0.1, 0.2, 0.3, 0.5, 1.0, 2.0, 5.0)
```

0.3초는 SLO, 0.5초는 alert 임계다. 해당 구간에 bucket을 직접 두어 p95 계산의
해석을 명확히 했다.

DB 메트릭은 paging 기준이 아니다. 사용자가 겪는 증상은 Error Rate와 Latency로
감지하고, DB 메트릭은 원인 분석에 사용한다.

---

## 5. Alert 설계

Alert는 cause가 아니라 user-facing symptom을 기준으로 둔다. CPU, memory,
DB 오류 자체에는 paging하지 않는다. 사용자가 실제로 실패하거나 느려졌을 때
알림이 발생해야 한다.

| Alert | 조건 | for | Severity | 목적 |
|---|---|---:|---|---|
| `APIInstanceDown` | `up{job="api"} == 0` | 1m | critical | scrape 불가, 관측 불능 |
| `HighErrorRate` | 5xx 비율 > 5% and RPS > 0.1 | 2m | critical | 사용자 실패 감지 |
| `HighLatencyP95` | p95 > 500ms and RPS > 0.1 | 2m | warning | 사용자 지연 감지 |

Error Rate와 Latency alert에는 traffic guard를 둔다.

```promql
and sum(rate(http_requests_total{route=~"/api/v1/.*"}[2m])) > 0.1
```

트래픽이 거의 없으면 비율 신호가 의미 없어지고, 1건의 실패가 100%처럼 보일 수
있기 때문이다.

SLO와 alert 임계값은 분리했다.

| 항목 | SLO | Alert |
|---|---|---|
| Error Rate | 5분 1% 이하 | 2분 5% 초과 |
| Latency p95 | 5분 300ms 이하 | 2분 500ms 초과 |

SLO는 장기 목표이고, alert는 운영자 개입이 필요한 신호다. alert는 더 짧은
윈도우와 더 높은 임계값을 사용해 일시적 노이즈를 줄인다.

모든 rule은 `prometheus/alert-rules.yml`에 코드로 관리한다.

---

## 6. Dashboard 설계

Dashboard는 운영자가 1분 안에 상태를 좁혀갈 수 있도록 다음 순서로 배치했다.

| 순서 | 패널 | 질문 |
|---|---|---|
| 1 | Scrape Status | Prometheus가 API를 관측 중인가? |
| 2 | Request Rate | 트래픽이 들어오고 있는가? |
| 3 | Error Rate | 사용자가 5xx를 보고 있는가? |
| 4 | Availability | 최근 누적 성공률은 어떤가? |
| 5 | Latency p95 | 응답이 느려졌는가? |
| 6 | Status Distribution | 어떤 status가 늘었는가? |
| 7 | DB Query Latency | DB가 느린가? |
| 8 | DB Errors Rate | DB 호출이 실패하는가? |

`Scrape Status`는 사용자 가용성이 아니다. `up == 1`이어도 DB 장애로 사용자 API가
5xx를 반환할 수 있다. 사용자 영향은 Error Rate, Availability, Latency 패널로
판단한다.

`api_fault_mode{mode!="normal"} == 1`은 Grafana annotation으로 표시한다.
fault-mode slow처럼 5xx 없이 latency만 증가하는 경우, 장애 주입 시각을 명확히
남기기 위해서다.

DB 패널은 5분 window를 사용한다. paging alert의 2분 window보다 길게 두어 RCA
단계에서 더 안정적인 진단 신호를 제공한다.

모든 datasource와 dashboard는 `grafana/provisioning/`으로 자동 등록된다. 평가자는
Grafana UI에서 수동 설정을 하지 않아도 된다.

---

## 7. 장애 시나리오와 검증 방향

| 시나리오 | Trigger | 기대 신호 | 목적 |
|---|---|---|---|
| DB stop | `docker stop sre-postgres` | `/readyz` 503, 사용자 5xx 증가, `HighErrorRate` firing, DB error 증가 | 의존성 장애가 사용자 SLI로 전파되는 흐름 검증 |
| Latency fault | `POST /admin/fault-mode {"mode":"slow"}` | p95 latency 증가, `HighLatencyP95` firing, Error Rate는 정상 | 오류 없이 느려지는 장애 검증 |

복구는 명령 실행이 아니라 지표로 판단한다.

- alert resolved
- Error Rate가 정상 범위로 복귀
- Latency p95가 300ms 이하로 복귀
- DB incident의 경우 `/readyz` 200과 DB error 증가 중단 확인

자동화 스크립트와 evidence JSON은 제출 부록 성격이다. 핵심 판단은
`incident_report.pdf`에서 요약한다.

---

## 8. 한계와 확장 방향

| 한계 | 이유 | 실서비스 확장 |
|---|---|---|
| 단일 인스턴스 | 과제 재현성 우선 | Kubernetes deployment, rolling update |
| Docker Compose readiness routing 부재 | Compose는 `/readyz` 실패 시 트래픽을 자동 차단하지 않음 | K8s readiness probe, LB health check |
| Prometheus 장기 보관 없음 | 데모 환경 | remote write, Thanos/Mimir |
| Alertmanager 없음 | 과제는 alert firing 확인이 목적 | Alertmanager, PagerDuty/Slack routing |
| 단일 임계 alert | 구현 단순성 | multi-window multi-burn-rate alert |
| 구조화 로그/trace 없음 | 범위 통제 | OpenTelemetry, Loki/Tempo |
| `/admin/fault-mode` 인증 없음 | 장애 재현 편의 | 내부망 격리, 인증, 별도 admin plane |

이 프로젝트는 복잡한 인프라를 많이 붙이는 것이 아니라, 작은 서비스를 대상으로
정상 상태를 정의하고 그 기준이 깨지는 흐름을 데이터로 검증하는 데 집중한다.
