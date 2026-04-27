# Incident Evidence

이 디렉터리는 장애 시나리오 실행 중 수집한 Prometheus alert/metric 스냅샷을
보관합니다. 화면 캡처가 아니라 JSON evidence입니다.

## Files

```text
evidence/
├── db-stop/
│   ├── 01-baseline.json
│   ├── 02-alert-firing.json
│   ├── 03-service-recovered.json    # /readyz=200 복구, alert는 아직 firing (rolling 2m window 잔존)
│   ├── 04-alert-resolved.json       # alert resolved (단, db_errors_5m은 5m window로 잔여 가능)
│   └── timeline.txt
└── latency/
    ├── 01-baseline.json
    ├── 02-alert-firing.json
    ├── 03-alert-resolved.json
    └── timeline.txt
```

파일명은 시점의 의미를 반영합니다.

- `service-recovered`: 사용자 영향(/readyz, request) 회복. **alert는 rolling
  window로 인해 아직 firing**일 수 있습니다.
- `alert-resolved`: Prometheus alert가 resolved 상태로 전환. 다만 **DB
  diagnostic 메트릭(`db_errors_5m`, `db_latency_p95_5m`)은 rolling 5m
  window로 인해 잔여값이 남을 수 있습니다.** 복구 검증은 alert state +
  user-facing SLI 회복으로 판단합니다.

## Meaning

| Scenario | Purpose | Main signal |
|---|---|---|
| `db-stop` | Postgres 중지로 의존성 장애가 사용자 SLI로 전파되는지 검증 | `HighErrorRate`, DB errors |
| `latency` | 5xx 없이 latency만 악화되는지 검증 | `HighLatencyP95` |

DB stop 시나리오에서는 DB timeout 영향으로 `HighLatencyP95`도 함께 firing될 수
있습니다. RCA에서는 `HighErrorRate`를 메인 감지 신호로, latency 상승을 동반
증상으로 다룹니다.

## Regenerate

```bash
docker compose --profile load up -d --build
bash scripts/incident-db-stop.sh        # 메인
bash scripts/incident-latency.sh        # 보조
```

각 스크립트는:
1. 시작 시 해당 디렉터리의 기존 JSON/timeline.txt 정리 (부분 실패 시 잔여 방지)
2. `scripts/collect-evidence.py`를 호출해 dashboard와 같은 PromQL 결과 저장
3. 종료 시 `timeline.txt`에 발생/감지/복구 시각 요약

**시나리오 실행 순서 권고**: db-stop 직후 latency를 실행하면 latency baseline에
DB의 5m rolling window 잔여가 일부 보일 수 있습니다. 깨끗한 baseline을 원하면
**latency를 먼저 실행**하거나 두 시나리오 사이 5분 이상 대기하세요. 본
프로젝트의 evidence는 db-stop을 메인으로 가정해 db-stop을 먼저 실행한
상태로 캡처되어 있습니다.
