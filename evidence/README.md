# Incident Evidence

장애 시나리오 실행 중 수집한 Prometheus alert/metric 스냅샷입니다.
화면 캡처가 아니라 JSON evidence입니다.

## Files

```text
evidence/
├── db-stop/
│   ├── 01-baseline.json
│   ├── 02-alert-firing.json
│   ├── 03-service-recovered.json
│   ├── 04-alert-resolved.json
│   └── timeline.txt
└── latency/
    ├── 01-baseline.json
    ├── 02-alert-firing.json
    ├── 03-alert-resolved.json
    └── timeline.txt
```

## Meaning

| Scenario | Purpose | Main signal |
|---|---|---|
| `db-stop` | `fault-mode=normal`에서 DB 장애가 사용자 SLI로 전파되는지 검증 | `HighErrorRate`, DB errors |
| `latency` | DB 정상 상태에서 5xx 없이 latency만 악화되는지 검증 | `HighLatencyP95` |

DB stop 시나리오에서는 DB timeout 영향으로 `HighLatencyP95`도 함께 firing될 수
있습니다. RCA에서는 `HighErrorRate`를 메인 감지 신호로 다룹니다.

## Regenerate

```bash
docker compose --profile load up -d --build
bash scripts/incident-db-stop.sh
bash scripts/incident-latency.sh
```

각 스크립트는 시작 시 기존 JSON/timeline을 정리한 뒤 새 evidence를 생성합니다.
