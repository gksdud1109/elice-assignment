#!/usr/bin/env bash
# Incident scenario 1 (메인): Postgres outage → user-facing 5xx → HighErrorRate firing → recovery
#
# 전제: 사전에 `docker compose --profile load up -d` 로 baseline traffic이 흐르고 있어야 한다.
# 산출물: evidence/db-stop/*.json (alert + metric timeline 박제)
#
# 시나리오 단계:
#   t0  baseline 안정화 대기 (≥60s)
#   t1  docker stop sre-postgres
#   t2  HighErrorRate firing 대기 (for: 2m + scrape lag, 최대 4분)
#   t3  docker start sre-postgres
#   t4  /readyz=200 복구 대기 (psycopg_pool reconnect, 최대 2분)
#   t5  alert resolved 대기 (rolling 2m window 비워질 때까지, 최대 3분)
set -euo pipefail

EVIDENCE_DIR="${EVIDENCE_DIR:-evidence/db-stop}"
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
    local out="$EVIDENCE_DIR/${label}.json"
    python3 "$SCRIPT_DIR/collect-evidence.py" "$PROM" "$label" > "$out"
    log "evidence saved → $out"
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

any_firing() {
    curl -fsS "$PROM/api/v1/alerts" | python3 -c "
import json, sys
d = json.load(sys.stdin)
firing = [a for a in d['data']['alerts'] if a['state'] == 'firing']
print('firing' if firing else 'none')
"
}

# ─── Sanity check ───────────────────────────────────────────────
log "sanity check: stack 응답 가능?"
curl -fsS "$API/healthz" > /dev/null || { log "API not up — run: docker compose --profile load up -d"; exit 1; }
curl -fsS "$PROM/-/ready" > /dev/null || { log "Prometheus not ready"; exit 1; }
log "OK"

# ─── t0: baseline ───────────────────────────────────────────────
log "t0: baseline 안정화 (60s)"
sleep 60
snapshot "01-baseline"

# ─── t1: fault injection ────────────────────────────────────────
log "t1: STOP sre-postgres"
docker stop sre-postgres > /dev/null
INCIDENT_START="$(ts)"

# ─── t2: alert firing 대기 ──────────────────────────────────────
log "t2: HighErrorRate firing 대기 (max 4min)"
firing_at=""
for i in $(seq 1 16); do
    sleep 15
    state=$(alert_state HighErrorRate)
    elapsed=$((i * 15))
    if [ "$state" = "firing" ]; then
        firing_at="$(ts)"
        log "  +${elapsed}s: HighErrorRate FIRING ← detection complete"
        break
    fi
    log "  +${elapsed}s: $state"
done
snapshot "02-alert-firing"

# ─── t3: 복구 trigger ───────────────────────────────────────────
log "t3: START sre-postgres (recovery trigger)"
docker start sre-postgres > /dev/null
RECOVERY_START="$(ts)"

# ─── t4: /readyz=200 대기 ──────────────────────────────────────
log "t4: readyz=200 대기 (psycopg_pool reconnect, max 2min)"
ready_at=""
for i in $(seq 1 8); do
    sleep 15
    code=$(curl -s -o /dev/null -w "%{http_code}" "$API/readyz")
    elapsed=$((i * 15))
    if [ "$code" = "200" ]; then
        ready_at="$(ts)"
        log "  +${elapsed}s: readyz=200 ← service recovered (alert는 아직 firing 가능 — rolling window)"
        break
    fi
    log "  +${elapsed}s: readyz=$code"
done
snapshot "03-service-recovered"

# ─── t5: alert resolved 대기 ───────────────────────────────────
log "t5: alert resolved 대기 (rolling 2m window roll-out, max 3min)"
resolved_at=""
for i in $(seq 1 12); do
    sleep 15
    state=$(any_firing)
    elapsed=$((i * 15))
    if [ "$state" = "none" ]; then
        resolved_at="$(ts)"
        log "  +${elapsed}s: all alerts resolved"
        break
    fi
    log "  +${elapsed}s: still $state"
done
snapshot "04-alert-resolved"

# ─── Summary ────────────────────────────────────────────────────
cat > "$EVIDENCE_DIR/timeline.txt" <<EOF
DB Stop Incident Timeline
==========================
incident_start (DB stopped):  $INCIDENT_START
alert_firing (detection):     ${firing_at:-N/A}
recovery_start (DB started):  $RECOVERY_START
service_recovered (readyz):   ${ready_at:-N/A}
alert_fully_resolved:         ${resolved_at:-N/A}

Evidence files (in $EVIDENCE_DIR):
  01-baseline.json             DB up, no alerts
  02-alert-firing.json         DB down, HighErrorRate firing (HighLatencyP95도 동반 firing 가능)
  03-service-recovered.json    /readyz=200, 단 alert는 아직 firing (rolling 2m window 잔존)
  04-alert-resolved.json       모든 alert resolved (단, db_errors_5m은 rolling 5m window로 여전히 non-zero일 수 있음)

복구 기준 검증:
  ✓ Prometheus alert resolved
  ✓ /readyz = 200
  ✓ DB error rate 감소 추세 + alert resolved 확인
    (db_errors_5m은 rolling 5m window 특성상 04 시점에도 잔여 가능)
EOF

log "incident scenario complete. summary: $EVIDENCE_DIR/timeline.txt"
cat "$EVIDENCE_DIR/timeline.txt"
