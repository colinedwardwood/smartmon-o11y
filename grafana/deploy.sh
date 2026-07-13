#!/bin/bash
# deploy.sh — Push Drive Health dashboards and alerts to Grafana Cloud
#
# Reads the API key from ~/.tokens/grafana-cew/grafana-api.key by default.
# Override with: GRAFANA_API_KEY=xxx ./deploy.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GRAFANA_URL="${GRAFANA_URL:-https://cew.grafana.net}"
GRAFANA_API_KEY="${GRAFANA_API_KEY:-$(cat "$HOME/.tokens/grafana-cew/grafana-api.key" 2>/dev/null || echo '')}"
PROM_UID="grafanacloud-prom"

FOLDER_TITLE="Drive Health"
FOLDER_UID="drive-health"
ALERT_GROUP="Drive%20Health"

if [[ -z "$GRAFANA_API_KEY" ]]; then
  echo "ERROR: GRAFANA_API_KEY is not set and ~/.tokens/grafana-cew/grafana-api.key not found." >&2
  exit 1
fi

AUTH="Authorization: Bearer $GRAFANA_API_KEY"

log()  { printf '\n\033[1;34m▶ %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. Create folder (idempotent — GET existing if POST returns conflict)
# ---------------------------------------------------------------------------
log "Ensuring folder '$FOLDER_TITLE' exists..."

HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  -H "$AUTH" -H "Content-Type: application/json" \
  -d "{\"title\": \"$FOLDER_TITLE\", \"uid\": \"$FOLDER_UID\"}" \
  "$GRAFANA_URL/api/folders")

if [[ "$HTTP_STATUS" == "200" ]]; then
  ok "Folder created."
elif [[ "$HTTP_STATUS" == "409" || "$HTTP_STATUS" == "412" ]]; then
  ok "Folder already exists."
else
  fail "Unexpected status $HTTP_STATUS creating folder."
fi

FOLDER_RESP=$(curl -sf -H "$AUTH" "$GRAFANA_URL/api/folders/$FOLDER_UID")
FOLDER_UID_ACTUAL=$(python3 -c "import sys,json; print(json.loads('$FOLDER_RESP')['uid'])" 2>/dev/null || \
  echo "$FOLDER_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['uid'])")
ok "Folder UID: $FOLDER_UID_ACTUAL"

# ---------------------------------------------------------------------------
# 2. Push dashboards
# ---------------------------------------------------------------------------
log "Pushing dashboards..."

for DASH_FILE in "$SCRIPT_DIR/dashboards/"*.json; do
  DASH_NAME=$(basename "$DASH_FILE" .json)

  PAYLOAD=$(python3 - "$DASH_FILE" "$FOLDER_UID_ACTUAL" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
d.pop("id", None)   # remove id so Grafana assigns one
payload = {"dashboard": d, "folderUid": sys.argv[2], "overwrite": True, "message": "deployed via deploy.sh"}
print(json.dumps(payload))
PYEOF
)

  RESP=$(echo "$PAYLOAD" | curl -sf -X POST \
    -H "$AUTH" -H "Content-Type: application/json" \
    -d @- \
    "$GRAFANA_URL/api/dashboards/db")

  STATUS=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('status','?'))" 2>/dev/null || echo "?")
  URL=$(echo "$RESP"    | python3 -c "import sys,json; print(json.load(sys.stdin).get('url',''))"    2>/dev/null || echo "")
  ok "$DASH_NAME  →  $STATUS  $GRAFANA_URL$URL"
done

# ---------------------------------------------------------------------------
# 3. Push alert rules (rule-groups API — idempotent PUT)
# ---------------------------------------------------------------------------
log "Pushing alert rules..."

ALERTS_FILE="$SCRIPT_DIR/alerts/smartmon-alerts.json"

HTTP_STATUS=$(curl -s -o /tmp/smartmon-alert-resp.json -w "%{http_code}" -X PUT \
  -H "$AUTH" -H "Content-Type: application/json" \
  --data @"$ALERTS_FILE" \
  "$GRAFANA_URL/api/v1/provisioning/folder/$FOLDER_UID_ACTUAL/rule-groups/$ALERT_GROUP")

if [[ "$HTTP_STATUS" == "202" || "$HTTP_STATUS" == "200" ]]; then
  RULE_COUNT=$(python3 -c "import json; d=json.load(open('$ALERTS_FILE')); print(len(d.get('rules',[])))")
  ok "$RULE_COUNT alert rules pushed to folder '$FOLDER_TITLE' / group 'Drive Health'."
else
  echo "Response body:" >&2
  cat /tmp/smartmon-alert-resp.json >&2
  fail "Alert rule push failed with HTTP $HTTP_STATUS."
fi

# ---------------------------------------------------------------------------
log "Done."
echo ""
echo "  Dashboards: $GRAFANA_URL/dashboards/f/$FOLDER_UID_ACTUAL"
echo "  Alerts:     $GRAFANA_URL/alerting/list"
echo ""
