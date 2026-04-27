#!/usr/bin/env bash
# Incident scenario 2 (보조): fault-mode slow 700ms → user p95 latency 침범 → HighLatencyP95 firing → recovery
#
# DB stop 시나리오와 달리 fault가 application 레이어에서 latency만 주입되므로
# Error Rate는 변하지 않고 Latency p95만 SLO를 침범한다. HighLatencyP95 alert가
# 단독으로 firing되는 시나리오를 시연한다.
#
# 전제: 사전에 `docker compose --profile load up -d` 로 baseline traffic.
# 산출물: evidence/latency/*.json
set -euo pipefail

EVIDENCE_DIR="${EVIDENCE_DIR:-evidence/latency}"
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

# baseline은 이전 시나리오의 잔여 데이터가 있을 수 있으니 추가로 90s 안정화
log "t0: baseline 안정화 (90s — rolling window 완전 비우기)"
sleep 90
snapshot "01-baseline"

# ─── fault injection ────────────────────────────────────────────
log "t1: fault-mode slow 700ms 주입"
curl -fsS -X POST "$API/admin/fault-mode" \
    -H 'Content-Type: application/json' \
    -d '{"mode":"slow","delay_ms":700}' > /dev/null
INCIDENT_START="$(ts)"

# ─── alert firing 대기 ─────────────────────────────────────────
log "t2: HighLatencyP95 firing 대기 (max 4min)"
firing_at=""
for i in $(seq 1 16); do
    sleep 15
    state=$(alert_state HighLatencyP95)
    elapsed=$((i * 15))
    if [ "$state" = "firing" ]; then
        firing_at="$(ts)"
        log "  +${elapsed}s: HighLatencyP95 FIRING"
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

# fault-mode 복귀는 즉시 효과 (in-process). p95는 rolling window 잔여로 즉시 떨어지지 않음.
log "t4: alert resolved 대기 (rolling 2m window roll-out, max 3min)"
resolved_at=""
for i in $(seq 1 12); do
    sleep 15
    state=$(alert_state HighLatencyP95)
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
Latency Incident Timeline
==========================
incident_start (slow 주입):    $INCIDENT_START
alert_firing (detection):      ${firing_at:-N/A}
recovery_start (normal 복귀):  $RECOVERY_START
alert_resolved:                ${resolved_at:-N/A}

Evidence files (in $EVIDENCE_DIR):
  01-baseline.json         normal mode, no alerts
  02-alert-firing.json     slow mode, HighLatencyP95 firing (Error Rate는 변동 없음)
  03-alert-resolved.json   normal mode 복귀, alert resolved

복구 기준 검증:
  ✓ Prometheus alert resolved
  ✓ p95 latency < 300ms (03 evidence에서 확인)
  ✓ Error Rate는 변동 없음 (이 시나리오는 latency만 영향)

주의: db-stop 시나리오 직후에 본 시나리오를 실행했다면 baseline의 db_errors_5m,
db_latency_p95_5m 패널에 직전 incident의 5m rolling window 잔여가 보일 수 있다.
깨끗한 baseline을 원하면 두 시나리오 사이 5분 이상 대기하거나, latency 시나리오를
먼저 실행한다.
EOF

log "incident scenario complete. summary: $EVIDENCE_DIR/timeline.txt"
cat "$EVIDENCE_DIR/timeline.txt"
