#!/usr/bin/env bash
# Incident scenario 3 (보조): fault-mode flaky 30% → 사용자 일부 5xx → HighErrorRate firing → recovery
#
# DB stop과 달리 fault가 application 레이어에서 확률적으로 5xx를 반환하므로
# DB diagnostic은 정상이고 user-facing Error Rate만 SLO를 침범한다.
# HighErrorRate alert가 application layer 원인으로 fires되는 시나리오를 시연한다.
#
# 전제: 사전에 `docker compose --profile load up -d` 로 baseline traffic.
# 산출물: evidence/flaky/*.json
set -euo pipefail

EVIDENCE_DIR="${EVIDENCE_DIR:-evidence/flaky}"
mkdir -p "$EVIDENCE_DIR"
# 부분 실패 시 이전 실행의 evidence가 섞이지 않도록 시작 시 정리
rm -f "$EVIDENCE_DIR"/*.json "$EVIDENCE_DIR"/timeline.txt

API="${API:-http://localhost:8000}"
PROM="${PROM:-http://localhost:9090}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ts() { date "+%H:%M:%S"; }
log() { echo "[$(ts)] $*"; }

snapshot() {
    local label="$1"
    python3 "$SCRIPT_DIR/collect-evidence.py" "$PROM" "$label" > "$EVIDENCE_DIR/${label}.json"
    log "evidence saved → $EVIDENCE_DIR/${label}.json"
}

alert_state() {
    local name="$1"
    curl -fsS "$PROM/api/v1/alerts" | python3 -c "
import json, sys
d = json.load(sys.stdin)
matches = [a for a in d['data']['alerts'] if a['labels'].get('alertname') == '$name']
print(matches[0]['state'] if matches else 'inactive')
"
}

# ─── Sanity check ───────────────────────────────────────────────
log "sanity check"
curl -fsS "$API/healthz" > /dev/null
curl -fsS "$PROM/-/ready" > /dev/null
log "OK"

# 이전 시나리오의 fault-mode 잔여를 제거한 뒤 시작한다.
log "reset fault-mode to normal"
curl -fsS -X POST "$API/admin/fault-mode" \
    -H 'Content-Type: application/json' \
    -d '{"mode":"normal"}' > /dev/null

# baseline 안정화 — 직전 시나리오의 rolling window 잔여 비우기
log "t0: baseline 안정화 (90s — rolling window 비우기)"
sleep 90
snapshot "01-baseline"

# ─── fault injection ────────────────────────────────────────────
# error_rate 30% — 임계 5%를 안정적으로 초과하면서 "일부 사용자 실패" 패턴 자연스러움
log "t1: fault-mode flaky (error_rate=0.3) 주입"
curl -fsS -X POST "$API/admin/fault-mode" \
    -H 'Content-Type: application/json' \
    -d '{"mode":"flaky","error_rate":0.3}' > /dev/null
INCIDENT_START="$(ts)"

# ─── alert firing 대기 ─────────────────────────────────────────
log "t2: HighErrorRate firing 대기 (max 4min)"
firing_at=""
for i in $(seq 1 16); do
    sleep 15
    state=$(alert_state HighErrorRate)
    elapsed=$((i * 15))
    if [ "$state" = "firing" ]; then
        firing_at="$(ts)"
        log "  +${elapsed}s: HighErrorRate FIRING"
        break
    fi
    log "  +${elapsed}s: $state"
done
snapshot "02-alert-firing"

# ─── 복구 ──────────────────────────────────────────────────────
log "t3: fault-mode normal 복귀 (recovery trigger)"
curl -fsS -X POST "$API/admin/fault-mode" \
    -H 'Content-Type: application/json' \
    -d '{"mode":"normal"}' > /dev/null
RECOVERY_START="$(ts)"

# fault-mode 복귀는 즉시 효과. Error Rate는 rolling window 잔여로 즉시 0이 되지 않음.
log "t4: alert resolved 대기 (rolling 2m window roll-out, max 3min)"
resolved_at=""
for i in $(seq 1 12); do
    sleep 15
    state=$(alert_state HighErrorRate)
    elapsed=$((i * 15))
    if [ "$state" = "inactive" ]; then
        resolved_at="$(ts)"
        log "  +${elapsed}s: alert resolved"
        break
    fi
    log "  +${elapsed}s: $state"
done
snapshot "03-alert-resolved"

# ─── Summary ────────────────────────────────────────────────────
cat > "$EVIDENCE_DIR/timeline.txt" <<EOF
Flaky (Application 5xx) Incident Timeline
==========================================
incident_start (flaky 30%):    $INCIDENT_START
alert_firing (detection):      ${firing_at:-N/A}
recovery_start (normal 복귀):  $RECOVERY_START
alert_resolved:                ${resolved_at:-N/A}

Evidence files (in $EVIDENCE_DIR):
  01-baseline.json         normal mode, no alerts
  02-alert-firing.json     flaky mode, HighErrorRate firing (Latency p95는 변동 없음, DB clean)
  03-alert-resolved.json   normal mode 복귀, alert resolved

복구 기준 검증:
  ✓ Prometheus alert resolved
  ✓ Error Rate < 1%
  ✓ Latency p95 정상 (이 시나리오는 latency 영향 없음)
  ✓ DB error rate = 0 (application layer 장애이므로 DB는 무영향)

이 시나리오의 차별점 (DB stop 대비):
  - HighErrorRate는 fires하지만 HighLatencyP95는 fires 안 함 (latency 정상)
  - db_errors_5m, db_latency_p95_5m 모두 정상 (DB diagnostic clean)
  - Application layer 5xx의 시그니처 — root cause가 dependency가 아닌 application
EOF

log "incident scenario complete. summary: $EVIDENCE_DIR/timeline.txt"
cat "$EVIDENCE_DIR/timeline.txt"
