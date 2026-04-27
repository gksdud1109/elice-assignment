# Incident Evidence

장애 시나리오 실행 중 수집한 Prometheus alert/metric 스냅샷입니다.
화면 캡처가 아니라 JSON evidence입니다.

## Files

```text
evidence/
├── db-stop/                    dependency layer 장애 (확장 시나리오)
│   ├── 01-baseline.json
│   ├── 02-alert-firing.json
│   ├── 03-service-recovered.json
│   ├── 04-alert-resolved.json
│   └── timeline.txt
├── latency/                    application layer 지연 (문항 1: 의도적 지연)
│   ├── 01-baseline.json
│   ├── 02-alert-firing.json
│   ├── 03-alert-resolved.json
│   └── timeline.txt
└── flaky/                      application layer 5xx (문항 1: 의도적 5xx)
    ├── 01-baseline.json
    ├── 02-alert-firing.json
    ├── 03-alert-resolved.json
    └── timeline.txt
```

## Meaning

문항 1이 요구한 API의 3 동작(정상/지연/5xx)을 incident 시나리오와 1:1
매핑합니다. DB stop은 dependency layer로의 확장 시나리오입니다.

| Scenario | API 동작 | Layer | 의도 | Main signal |
|---|---|---|---|---|
| `latency` | 의도적 지연 | application | DB 정상 상태에서 latency만 악화 | `HighLatencyP95` 단독 |
| `flaky` | 의도적 5xx | application | DB 정상 상태에서 일부 사용자 5xx | `HighErrorRate` 단독, DB 오류 series 없음 |
| `db-stop` | (확장) | dependency | DB 장애가 사용자 SLI로 전파 | `HighErrorRate` + DB errors 증가 |

`HighErrorRate`는 `flaky`(application)와 `db-stop`(dependency) 양쪽에서
firing되지만, DB diagnostic 메트릭(`db_errors_5m`, `db_latency_p95_5m`)으로
두 layer를 구분합니다. DB stop 시나리오에서는 DB timeout 영향으로
`HighLatencyP95`도 함께 firing될 수 있습니다.

## Regenerate

```bash
docker compose --profile load up -d --build
bash scripts/incident-latency.sh    # application 지연
bash scripts/incident-flaky.sh      # application 5xx
bash scripts/incident-db-stop.sh    # dependency (확장)
```

각 스크립트는 시작 시 `fault-mode=normal`로 초기화 + 기존 JSON/timeline 정리
후 새 evidence를 생성합니다.
