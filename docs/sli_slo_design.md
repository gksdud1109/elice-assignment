# SLI / SLO 설계 문서

본 문서는 Elice SRE 미니 프로젝트의 가상 서비스를 대상으로, 신뢰성을
정의하고 측정하기 위한 설계 결정을 정리한다. 지표, 임계값, 제외 범위는
각각의 운영 목적과 제약을 함께 설명한다.

---

## 1. 서비스 개요

### 1.1 가상 페르소나

본 과제의 API 서버는 비즈니스 기능 구현이 아니라 SLI/SLO 검증을 위한
**reliability test target**이다. 따라서 의도적으로 도메인 로직을 최소화하고,
다음과 같은 가상 서비스를 가정해 SLO 수치의 근거로 삼는다.

| 항목 | 값 |
|---|---|
| 서비스 | Elice 강의 카탈로그 조회 API (`/api/v1/courses`) |
| 트래픽 패턴 | 동기 read-heavy, 단순 조회 |
| 사용자 | 학습 플랫폼 일반 사용자 |
| 외부 의존성 | Postgres 1개 (단일 인스턴스, courses 테이블 조회) |
| 배포 형태 | 단일 컨테이너 인스턴스 |

의존성을 의도적으로 Postgres 하나로 제한했다. 목적은 비즈니스 기능 구현이
아니라 **dependency failure propagation**(의존성 장애가 user-facing SLI로
드러나는 흐름)을 시연하기 위함이다. ORM, migration tool, 캐시 layer는
의도적으로 제외했다 (§7 한계와 확장 방향 참고).

### 1.2 평가 범위

다음은 의도적으로 본 과제의 범위 밖이다.

- 비즈니스 로직 복잡성 (Postgres는 의존성 모델링 목적으로만 최소 사용)
- HA, 멀티 리전, 무중단 배포
- Alertmanager를 통한 외부 알림 전달
- ORM, migration tool, 캐시 layer 등 추가 인프라

---

## 2. 사용자 관점 정상 상태 정의

> **정상 상태**: 사용자가 강의 목록 또는 상세를 요청했을 때, 수백 ms 이내에
> 5xx 없이 강의 데이터를 받는 상태.

이 정의(전제)는 두 가지 결정으로 이어진다.

**결정 1. `/healthz`가 200이라는 사실은 정상의 증거가 아니다.**

사용자는 healthz를 호출하지 않는다. liveness probe는 프로세스 생존 여부만
대답할 뿐, 사용자가 5xx를 보고 있는지 또는 응답이 느린지를 모른다. 따라서 모든
SLI는 사용자 요청의 결과(`/api/v1/*`)로만 측정한다.

**결정 2. `/readyz`는 트래픽을 받을 준비가 되었는지 확인한다.**

`/healthz`가 프로세스 생존 여부만 확인하는 것과 달리, `/readyz`는 DB에
`SELECT 1`을 1초 timeout으로 수행한다. 실패하면 503을 반환한다. 따라서
DB가 다운되거나 응답이 느려지면 readyz가 자동으로 not ready 상태가 된다.

**데모 환경의 한계**: 본 docker-compose 환경에는 Kubernetes
readiness probe나 LB health check가 없으므로, `/readyz`가 503을 반환해도
트래픽이 자동으로 차단되지 않는다. 즉, DB 장애 시 사용자 요청은 그대로
인입되어 5xx로 떨어진다. 이는 의도적 단순화이며, 운영 환경에서는 K8s
readiness probe → endpoint 제거 → 트래픽 차단의 흐름으로 확장된다 (§7.9).

### 2.1 SLI 집계 범위

모든 SLI PromQL은 다음 필터를 사용한다.

```promql
{route=~"/api/v1/.*"}
```

집계에서 명시적으로 **제외**되는 경로:

| 경로 | 제외 이유 |
|---|---|
| `/healthz`, `/readyz` | probe 트래픽은 사용자 경험을 반영하지 않음 |
| `/metrics` | Prometheus scrape 트래픽 |
| `/admin/*` | 운영자(또는 chaos 도구)의 관리 트래픽 |

이 필터를 빠뜨리면 probe와 관리 트래픽이 분모에 섞여 SLI 신호가 희석될 수 있다.

예를 들어 사용자 API의 실패와 비슷한 양의 probe/admin 성공 응답이 함께 집계되면
실제 사용자 영향보다 error rate가 낮게 보이고, 알림 판단이 늦어질 수 있다.

---

## 3. SLI / SLO 정의와 근거

3개의 SLI를 정의하며, 각각의 역할이 다르다.

| SLI | 측정식 (개념) | SLO | 윈도우 | 역할 |
|---|---|---:|---:|---|
| Availability | 1 − (5xx / total) | **99.9%** | 30일 누적 | 장기 사용자 성공률, 에러버짓 |
| Error Rate | 5xx / total | **≤ 1%** | 5분 | 단기 장애 감지 운영 신호 |
| Latency p95 | histogram_quantile(0.95, …) | **≤ 300ms** | 5분 | 사용자 체감 응답 시간 |

### 3.1 Availability와 Error Rate의 역할 구분

수식만 보면 두 SLI는 사실상 동일하다 (`1 − error_rate = availability`).
그럼에도 두 개를 모두 정의하는 이유는 **시간 스케일과 의사결정 목적이 다르기**
때문이다.

- **Availability (30일 누적)**: 사용자에게 약속한 장기 신뢰도. 에러버짓
  소진을 추적하고, 배포 정책(예: 버짓 초과 시 신규 기능 배포 중단)의 입력값.
  Grafana 대시보드에서 30일 추세로 표시된다.
- **Error Rate (단기 운영 신호)**: 지금 장애가 발생 중인지 감지한다. SLO
  정량 표현은 5분 윈도우 ≤ 1%지만, 실제 alert는 더 짧은 2분 윈도우와 더
  보수적인 5% 임계를 사용한다. 이는 빠른 감지와 false positive 회피 사이의
  trade-off (§5.4).

문서/대시보드/알림에서 둘을 같은 패널/같은 임계로 다루지 않도록 분리해
표기한다.

### 3.2 PromQL 정의

```promql
# Availability - 30일 누적 (개념 정의)
sum(increase(http_requests_total{route=~"/api/v1/.*", status!~"5.."}[30d]))
/
sum(increase(http_requests_total{route=~"/api/v1/.*"}[30d]))

# Error Rate - 5분 단기
sum(rate(http_requests_total{route=~"/api/v1/.*", status=~"5.."}[5m]))
/
sum(rate(http_requests_total{route=~"/api/v1/.*"}[5m]))

# Latency p95 - 5분 단기
histogram_quantile(0.95,
  sum by(le) (rate(http_request_duration_seconds_bucket{route=~"/api/v1/.*"}[5m]))
)
```

> **데모 환경 주의**: 본 데모는 Prometheus storage가 ephemeral이므로 30일
> 실측이 불가하다 (§7.3). Dashboard와 실 검증은 1시간/6시간 윈도우를 단기
> proxy로 사용하며, 위 30일 query는 운영 환경에서의 본래 정의에 해당한다.

### 3.3 4xx의 분류

4xx는 SLI 산정에서 success로 본다. PromQL `status!~"5.."` 필터는 5xx만
제외하므로 4xx 응답은 자동으로 분자(성공)에 포함된다. 근거는 다음과 같다.

- 4xx는 클라이언트 잘못된 요청에서 비롯되며, 서비스의 신뢰성 문제로 보기 어렵다.
- 단, 401/403의 비정상 급증, 또는 의도치 않은 404 폭증은 별도 신호로 다룰
  가치가 있다 (확장 방향에 명시).

### 3.4 SLO 수치의 근거

**Availability 99.9% (30일)** = 약 43.2분/월의 다운타임 허용.

| 후보 | 결정 | 근거 |
|---|---|---|
| 99.5% | 기각 | 월 3.6시간 허용. 학습 플랫폼의 기본 조회 API 기준으로 허용량이 크다. |
| **99.9%** | **채택** | 월 43분 허용. 단일 incident와 짧은 정비 시간을 흡수할 수 있는 현실적 수준이다. |
| 99.95% | 기각 | 월 22분 허용. HA/멀티 인스턴스가 없는 본 과제 범위와 맞지 않는다. |

**Error Rate ≤ 1% (5분)**: 5분 윈도우에서 5xx 비율 1% 초과는 사용자 관점의
degradation. SLO 신호용 정의이며, 알림 임계는 별도로 5%로 더 보수적이다
(§5.2 참조).

**Latency p95 ≤ 300ms**: 사용자 체감 지연(약 100~250ms) 마지노선과 read-only
단순 쿼리의 합리적 응답 시간을 결합한 수치. p99는 demo 수준 RPS에서 노이즈
민감도가 높아 p95가 신호 대 잡음 비율이 좋다.

### 3.5 에러버짓과 burn rate

```
Error budget = 100% - 99.9% = 0.1%
30일 기준 = 30 × 24 × 60 × 0.001 분 = 43.2 분/30일
```

burn rate는 현재 error rate가 budget rate에 비해 몇 배 빠른지를 나타낸다.
alert 임계인 5% error rate를 burn rate로 환산하면:

```
burn rate = 5% / 0.1% = 50x
30일 budget 소진 시간 = 30일 / 50 ≈ 14.4시간
```

즉, 2분 윈도우에서 5%를 넘는 속도가 14.4시간 이상 지속되면 30일 SLO를 침범한다.
이 시간 여유 안에 운영자 개입(롤백, 트래픽 차단)이 들어갈 수 있도록 alert 임계와 윈도우를 설정했다.
정밀한 multi-window multi-burn-rate 알림(예: `1h × 14.4x + 6h × 6x`)은 §7 확장 방향에 명시했다.

---

## 4. Metrics 설계

### 4.1 RED 모델 채택

도메인 의존 USE 메트릭(CPU/Memory)이 아니라 사용자 요청 중심의 RED를
채택한다. 이유는 §5.1의 symptom-based alerting과 같다. 사용자가 겪는 증상이
원인 추정 지표보다 의사결정에 직접적이다.

| 분류 | 메트릭 |
|---|---|
| Rate | `http_requests_total{method, route, status}` (Counter) |
| Errors | 같은 메트릭에서 `status=~"5.."` 필터 |
| Duration | `http_request_duration_seconds{method, route}` (Histogram) |

### 4.2 라벨 cardinality 통제

`route` 라벨은 **route template** (예: `/api/v1/courses/{course_id}`)
으로 기록한다. 실제 path를 그대로 라벨링하면 `/api/v1/courses/1`,
`/api/v1/courses/2` … 가 모두 별개의 시계열을 만들어 cardinality가
불필요하게 증가한다.

미들웨어는 FastAPI가 라우팅을 마친 뒤 `request.scope["route"].path`에서
template을 읽어 라벨로 사용한다. unmatched 경로(404 등)는 `__unmatched__`
하나의 버킷으로 모아 cardinality 안전망으로 둔다.

의도적으로 라벨에서 제외된 항목: `user_id`, `session_id`, `request_id`,
`ip` 등 high-cardinality 식별자. 이런 정보는 trace/log에 남기고 metric에는
넣지 않는다.

### 4.3 Histogram bucket 선정

```python
LATENCY_BUCKETS_SECONDS = (0.05, 0.1, 0.2, 0.3, 0.5, 1.0, 2.0, 5.0)
```

`prometheus_client`의 기본 bucket은 `5ms ~ 10s`를 비균등하게 덮지만,
**SLO 목표(300ms)와 alert 임계(500ms) 근처에 정확한 bucket이 없다**. 이 경우
`histogram_quantile`이 선형 보간으로 추정하여 p95 오차가 수십 ms 단위로
커진다.

위 bucket은 0.3과 0.5에 정확히 경계를 두어 두 임계값 근처에서 정밀도를
확보한다. 5s 이상의 응답은 이 서비스의 정상 응답 범위를 벗어나므로 더 큰
bucket은 본 과제의 판단에는 사용하지 않는다.

### 4.4 보조 메트릭: `api_fault_mode`

```
api_fault_mode{mode="normal|slow|error|flaky"}  # gauge, 1=active, 0=inactive
```

장애 주입 모드를 메트릭으로 노출하는 이유는 두 가지다.

1. **Grafana annotation 자동 생성**: 모드 전환 시각이 dashboard 위에
   주석으로 표시되어, 운영자가 장애 주입 시작 시각을 확인할 수 있다.
2. **RCA 타임라인 자동화**: incident report 작성 시 발생/감지/복구 시각을
   수동으로 정리하지 않고 Prometheus query로 추출할 수 있다.

### 4.5 DB 메트릭 (diagnostic signal)

```
db_query_duration_seconds{operation}  # Histogram
db_errors_total{operation}            # Counter
```

DB 메트릭은 **paging alert 기준이 아니라 RCA 보조 지표**다. 사용자 영향
판단은 user-facing SLI(Error Rate, Latency p95)가 담당하며, DB 메트릭은
incident 발생 시 원인을 좁히는 용도다. 구현은 `psycopg_pool.ConnectionPool`을
사용해 요청마다 새 connection을 열지 않고, pool timeout과 query 실패를
`db_errors_total`에 기록한다.

이 분리의 근거:

- DB가 느려도 사용자가 영향을 받지 않을 수 있다 (예: timeout 안에 응답 완료).
- DB가 정상이어도 사용자가 영향을 받을 수 있다 (예: 애플리케이션 버그,
  네트워크 문제).
- symptom과 cause를 같은 alert에 묶지 않는 것이 SRE 원칙에 부합한다.

따라서 **`HighDBErrorRate` 같은 DB-specific paging alert는 의도적으로
만들지 않는다**. Grafana dashboard에는 두 메트릭에 해당하는 패널을
추가하여 incident 발생시 운영자가 즉시 참조할 수 있게 한다.

`operation` 라벨은 `readiness`, `list_courses`, `get_course` 세 가지로
제한되어 cardinality는 안전한 수준이다.

DB 메트릭의 dashboard query는 **5분 window**를 사용한다. paging
signal(2분 window)과 의도적으로 분리하는 이유와 NaN 처리는 §6.4 참조.

#### DB timeout 계층 (실서비스 확장)

본 과제는 **connection acquire timeout** 하나만 설정한다
(`pool.connection(timeout=2.0)`). 실서비스에서는 다음 3개를 함께 설정해야
느린 쿼리와 네트워크 지연이 worker pool을 장시간 점유하지 않는다.

| 종류 | 설정 위치 | 의미 |
|---|---|---|
| connection acquire | `pool.connection(timeout=...)` | pool에서 idle connection을 받기까지의 대기 한도 |
| statement | PostgreSQL `statement_timeout` (DSN parameter 또는 `SET LOCAL statement_timeout`) | SQL 한 문장의 실행 한도 |
| connect | `connect_timeout` (DSN parameter) | 신규 connection 수립 한도 |

본 과제는 seed table 단순 조회만 하므로 statement timeout 모델링이 불필요하나,
실 운영에서는 사용자 latency budget을 분해하여 각 timeout을 설정해야 한다
(예: SLO p95 300ms = connect 50ms + acquire 50ms + statement 200ms 합산).
이 세 timeout이 모두 적절히 설정되지 않으면 DB 일부 노드 장애가 worker
thread를 점유해 사용자 timeout cascade로 번질 수 있다.

---

## 5. Alert 설계

### 5.1 Symptom-based 채택

Alert는 사용자가 겪는 **증상** (`5xx`, latency, instance down)을 기반으로
하며, 원인 추정 지표(CPU 80%, memory 90% 등)는 사용하지 않는다.

| 비교 | Symptom-based | Cause-based |
|---|---|---|
| 신호 의미 | 사용자가 실제로 영향을 받음 | 영향 가능성 추측 |
| False positive | 상대적으로 낮음 | 상대적으로 높음 (CPU가 높아도 응답은 정상일 수 있음) |
| 새로운 장애 모드 대응 | 사용자 증상 기준으로 감지 가능 | 새 cause마다 rule 추가 필요 |

### 5.2 3개 필수 Alert

| Alert | Expression (요약) | for | Severity |
|---|---|---|---|
| `APIInstanceDown` | `up == 0` | 1m | critical |
| `HighErrorRate` | error rate > 5% **AND** RPS > 0.1 | 2m | critical |
| `HighLatencyP95` | p95 > 500ms **AND** RPS > 0.1 | 2m | warning |

Severity는 사용자 영향도 기준으로 분리한다.

- **critical (즉시 대응)**: 사용자가 응답을 못 받거나 5xx를 즉시 본다
  → `APIInstanceDown`, `HighErrorRate`
- **warning (notify)**: 사용자가 영향을 받지만 응답은 받는다
  → `HighLatencyP95`

`APIInstanceDown`은 엄밀히 user-visible SLI가 아닌 scrape 실패 기반이다.
다만 scrape 불가 = 관측 불능 + 인스턴스 장애를 동시에 의미하므로, 사용자
영향이 직접적인 critical로 둔다.

아래 PromQL은 `prometheus/alert-rules.yml`에 동일하게 구현되어 있다 (1:1 매칭).

상세 PromQL:

```promql
# HighErrorRate
(
  sum(rate(http_requests_total{route=~"/api/v1/.*",status=~"5.."}[2m]))
  /
  sum(rate(http_requests_total{route=~"/api/v1/.*"}[2m]))
) > 0.05
and
sum(rate(http_requests_total{route=~"/api/v1/.*"}[2m])) > 0.1

# HighLatencyP95
histogram_quantile(0.95,
  sum by(le) (rate(http_request_duration_seconds_bucket{route=~"/api/v1/.*"}[2m]))
) > 0.5
and
sum(rate(http_requests_total{route=~"/api/v1/.*"}[2m])) > 0.1
```

### 5.3 트래픽 가드의 필요성

`and sum(rate(...)) > 0.1`은 낮은 트래픽에서 알림의 의미를 유지하기 위한
조건이다.

- 트래픽이 매우 낮으면 1건의 5xx도 100% error rate로 보일 수 있다 (false positive).
- 분모가 0이면 비율 계산이 `NaN`이 되어 alert가 비정상적으로 동작한다.
- 0.1 RPS = 분당 6건. 그 미만의 트래픽이라면 SLI 신호 자체가 통계적으로
  의미가 약하다.

이 트래픽 가드는 데모 환경처럼 트래픽이 일정하지 않은 상황에서 특히
중요하며, `loadgen`이 멈춘 상태에서 잘못된 알림이 발화하는 것을 막는다.

### 5.4 임계값이 SLO와 다른 이유

| 항목 | SLO | Alert 임계 |
|---|---|---|
| Error Rate | 1% (5분) | 5% (2분) |
| Latency p95 | 300ms (5분) | 500ms (2분) |

알림은 사람이 개입해야 하는 burn 속도의 임계이지, SLO 침범 여부 자체를
표현하는 값은 아니다. 따라서 다음과 같이 분리한다.

- 윈도우는 더 짧게 설정한다 (5분 → 2분): 빠른 감지
- 임계값은 더 보수적으로 설정한다 (1% → 5%): false positive 감소

이 두 축의 trade-off가 multi-window multi-burn-rate 알림의 출발점이며,
본 과제에서는 단일 임계로 단순화하고 §7에 확장 경로를 명시한다.

### 5.5 MTTD / MTTR 목표

| 지표 | 목표 | 수단 |
|---|---|---|
| MTTD (감지 시간) | ≤ 3분 | 5s scrape × 2분 윈도우 → 약 2~3분 내 firing |
| MTTR (복구 시간) | ≤ 5분 | Runbook을 README에 인라인, fault-mode 토글 1콜 |

본 과제에서는 fault 주입/복구가 단일 API call이므로 MTTR이 수단상
실제 운영보다 짧다. RCA에서는 실제 장애라면 발견, 판단, 승인 시간이 추가로
발생한다는 점을 함께 기재한다.

### 5.6 No-data 정책과 alert 간 역할 분리

scrape 자체가 실패하면 (`up == 0`), `HighErrorRate`와 `HighLatencyP95`의
expr이 NaN이 되어 evaluation이 멈춘다. 이는 결함이 아니라 의도된 분리다.

- **`APIInstanceDown`** (1m, critical): scrape 자체 실패를 단독으로 담당
- **`HighErrorRate` / `HighLatencyP95`** (2m, ratio): 트래픽이 존재하는 한에서
  user-facing 신호를 담당

이 구조 덕분에 ratio alert에 `up == 1`을 추가 조건으로 묶지 않아도 paging
채널에 공백이 생기지 않는다. 또한 두 ratio alert의 PromQL이 단순해지고,
"트래픽이 있을 때만 의미 있는 신호"라는 의도가 분명해진다.

존재하지 않는 메트릭에 대한 Prometheus 기본 동작은 NaN → evaluation skip이며,
alert는 발화하지도 resolve하지도 않는다. 본 과제는 단일 인스턴스 단일 scrape
환경이라 `APIInstanceDown` 하나로 충분하다. 다중 인스턴스로 확장할 경우
`absent(up{job="api"})` 같은 dead-man's-switch alert를 별도로 추가해 "전체
job이 사라진" 케이스도 감지해야 한다.

---

## 6. Dashboard 설계

### 6.1 운영자 판단 순서로 배치

대시보드는 운영자가 짧은 시간 안에 정상/장애를 판정하는 순서로 설계한다.

| 순서 | 패널 | 답하는 질문 |
|---|---|---|
| 1 | Scrape Status (api) | scrape가 살아 있는가? (≠ 사용자 가용성) |
| 2 | Request Rate | 트래픽이 들어오고 있는가? (없으면 SLI 신호 무의미) |
| 3 | Error Rate % | 사용자가 실패를 보고 있는가? |
| 4 | Availability % | 장기 추세는 SLO 안에 있는가? |
| 5 | p95 Latency | 사용자가 느려진다고 느낄 만한가? |
| 6 | Status Code Distribution | 에러의 종류 분포는? (분류/원인 좁히기) |
| 7~8 | DB Query Latency / DB Errors Rate | (RCA 보조) 의존성에서 원인이 보이는가? |

위에서 아래로 읽으면 **생존 → 트래픽 → 장기/단기 사용자 영향 → 분류 → 의존성**
순서로 자연스럽게 의사결정이 좁혀진다.

**1번 패널의 명칭에 주의**: `Scrape Status`는 Prometheus가 `/metrics` endpoint에
도달 가능한지(=process 살아있고 네트워크 OK)만 본다. `up == 1`이라도 사용자
요청이 5xx로 떨어질 수 있고 (예: DB 의존성 장애), `up == 0`이어도 다른
인스턴스가 traffic을 받고 있을 수 있다 (멀티 인스턴스 환경). 따라서 사용자
영향은 항상 #3~5의 user-facing SLI 패널로 판단한다.

### 6.2 Annotation 통합

`api_fault_mode{mode!="normal"} == 1` query로 등록한 annotation을 모든 시계열
패널에 오버레이한다. `mode` 라벨로 normal을 명시적으로 제외하지 않으면
정상 구간에도 annotation이 찍혀 RCA 자료와 섞일 수 있다. 장애 주입 모드 활성
시각이 빨간 세로선으로 표시되어, 별도의 incident timeline 작성 없이도 dashboard
자체가 사후 분석 자료가 된다.

**DB 의존성 incident에는 별도 annotation을 만들지 않았다.** DB 장애는
세 가지 신호가 동시에 나타나기 때문에 추가 marker가 불필요하다.

1. `db_errors_total` 증가 (DB Errors Rate 패널에 즉시 visible)
2. `/readyz` 503 (Status Code Distribution 패널에 503 비율 증가)
3. `HighErrorRate` alert firing (paging signal)

반면 `fault-mode`는 정상 트래픽과 시각적으로 동일해 보일 수 있어 — 특히
`slow` 모드는 5xx 없이 latency만 증가시키므로 — 별도 annotation으로 명시적
marker가 필요하다.

### 6.3 Provisioning 자동화

모든 datasource와 dashboard는 `grafana/provisioning/`로 자동 등록된다.
수동 설정 없이 `docker compose up`만으로 운영 환경이 재현된다. 이는
운영 설정을 코드로 관리한다는 SRE 원칙에 맞다.

### 6.4 DB 패널의 window 분리 (paging vs diagnostic)

`HighErrorRate` / `HighLatencyP95`는 **2분 window**로 빠른 감지를 우선한다
(paging signal). 반면 DB 패널(`DB Query Latency p95`, `DB Errors Rate`)은
**5분 window**를 사용한다 (diagnostic signal). 분리 이유는 두 가지다.

1. **Diagnostic은 빠른 감지보다 RCA 정확도/안정성이 더 중요**: incident
   발생 시 운영자가 원인을 좁히는 신호이므로, transient noise보다 stable한
   추세가 가치 있다.
2. **Sample 부족 operation의 NaN 회피**: `readiness` 같은 호출 빈도 낮은
   operation은 2분 윈도우에서 sample이 부족해 `histogram_quantile`이
   NaN을 반환할 수 있다. 5분 윈도우는 더 많은 sample을 모아 안정 추정을
   확보한다. 추가로 dashboard query에 `> 0` 후행 필터를 두어 그래도
   NaN인 series는 표시하지 않는다.

이 window 분리는 **paging의 "빠른 감지"와 diagnostic의 "정확한 진단"을
의도적으로 분리한 설계**이며, SRE의 detection vs diagnosis 분업 원칙에
부합한다.

### 6.5 Error Rate / Availability 패널의 0% fallback

`Error Rate` 패널은 5xx가 0건일 때 PromQL 결과가 빈 vector가 되어 dashboard에
"no data"로 표시된다. 운영자가 "메트릭 수집 실패"로 오해할 수 있어, numerator를
`or vector(0)`로 감싸 명시적으로 0%로 표시한다.

```promql
(sum(rate(http_requests_total{route=~"/api/v1/.*",status=~"5.."}[2m])) or vector(0))
/
sum(rate(http_requests_total{route=~"/api/v1/.*"}[2m]))
```

`Availability 1h` 패널에도 같은 방식을 적용한다 (1h 윈도우라 5xx 0건은 더 자주
발생). 단, **alert rule에는 이 fallback을 적용하지 않는다** — alert는
트래픽 가드(`and sum(rate(...)) > 0.1`)로 별도 보호되며, fallback과 트래픽
가드의 의미가 다르다 (fallback은 시각적 명확성, 가드는 false positive 회피).

---

## 7. 한계와 확장 방향

본 과제의 의도적 단순화와 데모 환경 제약을 정리한다. 각 항목은 실서비스
운영 시 고려할 확장 경로를 함께 제시한다.

### 7.1 단일 인스턴스, in-memory fault state

- **한계**: 멀티 인스턴스 환경에서는 노드 간 fault mode가 어긋난다.
- **확장**: 외부 저장소(Redis), feature flag 시스템(LaunchDarkly,
  Unleash)으로 모드 동기화.

### 7.2 `/admin/fault-mode` 인증 없음

- **한계**: 평가 편의용. 실서비스라면 인증/네트워크 격리 없이는 위험.
- **확장**: 인증(mTLS, JWT, IAM), 내부망 격리 (separate VPC, sidecar
  proxy), 또는 admin endpoint 자체를 별도 컨테이너/포트로 분리.

### 7.3 Prometheus storage ephemeral

- **한계**: `docker compose down`시 메트릭 휘발. 30일 SLO를 실측 불가.
- **확장**: named volume, remote write to long-term storage (Thanos,
  Cortex, Mimir).

### 7.4 Alertmanager 미통합

- **한계**: Prometheus UI에서 firing 확인만 가능. 알림 전달 채널 없음.
- **확장**: Alertmanager 추가, severity별 라우팅 (critical → PagerDuty,
  warning → Slack), grouping/inhibition rule.

### 7.5 단일 임계 alert (multi-window 미적용)

- **한계**: 빠른 감지와 false positive 최소화의 trade-off가 단일 임계로
  타협되어 있음.
- **확장**: SRE Workbook ch.5의 multi-window multi-burn-rate
  - fast burn: 1h 윈도우, 14.4x burn rate (단기 급증)
  - slow burn: 6h 윈도우, 6x burn rate (장기 누수)
  - 두 조건 OR로 결합

### 7.6 분산 추적 / 로그 미통합

- **한계**: 메트릭만으로는 단일 요청의 root cause 추적 한계.
- **확장**: OpenTelemetry instrumentation → Tempo (trace), Loki (log).
  Grafana exemplar로 metric → trace 점프.

### 7.7 의존성 SLI (단일 의존성으로 부분 충족)

- **현황**: Postgres 단일 의존성에 대해서는 `db_query_duration_seconds`,
  `db_errors_total` diagnostic signal로 측정 (§4.5). `/readyz`가 SELECT 1로
  의존성 상태를 노출.
- **한계**: 다중 의존성 (캐시, downstream service)에 대한 SLI 통합 부재.
  의존성 SLO를 사용자 SLO와 어떻게 연결할지의 설계 (예: 합산 SLO
  `1 − Π(1 − SLO_i)`)는 본 과제 범위 밖.
- **확장**: dependency별 latency/availability SLI, end-to-end vs
  per-hop 분리 측정, dependency SLO에서 user SLO를 도출하는 모델.

### 7.8 4xx 신호 미활용

- **한계**: 4xx를 success로 분류하지만, 401/403 급증, 의도치 않은 404
  폭증 같은 패턴은 별개의 운영 신호가 될 수 있음.
- **확장**: `http_4xx_anomaly` 별도 SLI 또는 anomaly detection rule
  (`increase` 기반 z-score).

### 7.9 readiness probe와 traffic routing 분리

- **한계**: `/readyz`가 503을 반환해도 docker-compose 환경에는 트래픽을
  차단할 routing 계층(K8s readiness probe, LB health check)이 없으므로,
  사용자 요청이 그대로 인입되어 5xx로 떨어진다. 즉 readyz의 실용적 가치는
  본 데모에서 운영자가 의존성 상태를 확인하는 endpoint에 가깝다.
- **확장**: K8s readiness probe → Service endpoint 제거 → 트래픽 차단,
  또는 LB target health check + 인스턴스 격리. 운영 환경에서는 readyz 503이
  자동으로 사용자 영향을 줄이는 회로가 된다.

### 7.10 `depends_on: service_healthy`의 한계

- **한계**: docker-compose의 `depends_on: condition: service_healthy`는
  startup ordering만 보장한다. 운영 중 DB가 죽으면 자동 재기동/페일오버를
  하지 않는다.
- **확장**: connection pool의 retry/backoff (psycopg_pool은 reconnect를
  자동 시도), Kubernetes Pod restartPolicy + PostgreSQL operator (예:
  CloudNativePG)로 페일오버.

---

## 부록 A. 결정 일람

| # | 결정 | 근거 위치 |
|---|---|---|
| 1 | SLI 집계는 `route=~"/api/v1/.*"`만 | §2.1 |
| 2 | `/healthz`는 SLI 신호가 아님 | §2 |
| 3 | `/readyz`는 DB `SELECT 1`로 트래픽 수신 준비 상태를 검증 | §2 |
| 4 | Availability와 Error Rate 역할 분리 | §3.1 |
| 5 | Availability SLO 99.9% (월 43분 다운 허용) | §3.4 |
| 6 | Latency SLO p95 300ms | §3.4 |
| 7 | Histogram bucket을 SLO 임계값 근처로 직접 지정 | §4.3 |
| 8 | Alert는 symptom-based | §5.1 |
| 9 | Alert query에 트래픽 가드 (`> 0.1 RPS`) | §5.3 |
| 10 | Alert 임계값은 SLO보다 보수적 (5% / 500ms) | §5.4 |
| 11 | `api_fault_mode` gauge로 incident timeline 자동화 | §4.4, §6.2 |
| 12 | 모든 Grafana 설정은 provisioning으로 자동 등록 | §6.3 |
| 13 | Severity는 사용자 영향도 기준으로 분리 (critical: 즉시 대응, warning: 알림) | §5.2 |
| 14 | Annotation query에서 `mode!="normal"` 필터로 정상 구간 혼재 방지 | §6.2 |
| 15 | Postgres 1개를 dependency failure propagation 시연용으로 추가 (ORM/migration/캐시 제외) | §1.1, §7.7 |
| 16 | `/readyz`는 DB SELECT 1로 검증 — 다만 데모 환경에는 routing 계층이 없어 traffic 차단 미발생 | §2, §7.9 |
| 17 | DB 메트릭은 diagnostic signal로 분리, paging alert는 user-facing SLI가 담당 | §4.5 |
| 18 | DB incident는 별도 annotation 없이 `db_errors_total` + readyz 503 + HighErrorRate firing 세 신호로 시각화 | §6.2 |
| 19 | DB diagnostic 패널은 5m window — paging의 2m과 detection vs diagnosis 원칙으로 분리 | §6.4 |
| 20 | Error Rate / Availability 패널은 `or vector(0)` fallback — 5xx 0건도 명시 0% 표시 | §6.5 |
| 21 | API Up 패널을 `Scrape Status (api)`로 명명 — user-facing availability와 의미 분리 | §6.1 |
