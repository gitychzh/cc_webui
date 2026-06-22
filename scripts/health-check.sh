#!/usr/bin/env bash
#
# CloudCLI WebUI Health Check Script
# Runs on the remote server to verify the service is fully functional.
# Usage: ./scripts/health-check.sh
#
# Checks: port listening, health API, provider auth, WebSocket handshake, .env integrity
#

set -euo pipefail

PORT=3001
HEALTH_URL="http://localhost:${PORT}/health"
PROVIDER_AUTH_URL="http://localhost:${PORT}/api/providers/claude/auth/status"
WS_URL="ws://localhost:${PORT}/ws"
ENV_PATH="/home/opc2_uname/.cloudcli/.env"
PROJECT_ENV="/home/opc2_uname/cc_ps/cc_webui/.env"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0

log()   { echo -e "${BLUE}[CHECK]${NC} $*"; }
ok()    { echo -e "${GREEN}[PASS]${NC} $*"; PASS=$((PASS+1)); }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; FAIL=$((FAIL+1)); }

# ─── 1. Service Status ──────────────────────────────────────────────────
log "1. Checking systemd service..."
svc_status=$(systemctl is-active cloudcli 2>&1) || true
if [[ "$svc_status" == "active" ]]; then
    ok "cloudcli service: active (running)"
else
    fail "cloudcli service: ${svc_status}"
fi

svc_enabled=$(systemctl is-enabled cloudcli 2>&1) || true
if [[ "$svc_enabled" == "enabled" ]]; then
    ok "cloudcli service: enabled (auto-start)"
else
    fail "cloudcli service: NOT enabled — run: sudo systemctl enable cloudcli"
fi

# ─── 2. Port Listening ──────────────────────────────────────────────────
log "2. Checking port ${PORT}..."
port_check=$(ss -tlnp 2>/dev/null | grep ":${PORT}" ) || true
if [[ -n "$port_check" ]]; then
    ok "Port ${PORT}: listening (${port_check##*users:(})"
else
    fail "Port ${PORT}: NOT listening"
fi

# ─── 3. Health API ──────────────────────────────────��───────────────────
log "3. Checking /health endpoint..."
health=$(curl -sf --max-time 5 "${HEALTH_URL}" 2>&1) || true
if [[ -n "$health" ]]; then
    ok "/health API: ${health}"
else
    fail "/health API: unreachable or error"
fi

# ─── 4. Provider Auth ──────────────────────────────────────────────────
log "4. Checking Claude provider auth..."
auth=$(curl -sf --max-time 5 "${PROVIDER_AUTH_URL}" 2>&1) || true
if [[ -n "$auth" ]]; then
    # Parse key fields
    is_authenticated=$(echo "$auth" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['data']['authenticated'])" 2>/dev/null) || true
    if [[ "$is_authenticated" == "True" ]]; then
        ok "Claude provider: authenticated"
    else
        warn "Claude provider: NOT authenticated"
    fi
else
    fail "Claude provider auth: unreachable"
fi

# ─── 5. WebSocket Handshake ────────────────────────────────────────────
log "5. Checking WebSocket handshake..."
ws_result=$(curl -sf --max-time 3 --include \
    -H "Connection: Upgrade" \
    -H "Upgrade: websocket" \
    -H "Sec-WebSocket-Version: 13" \
    -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
    "http://localhost:${PORT}/ws" 2>&1) || true
ws_status=$(echo "$ws_result" | grep -o "HTTP/1.1 101" ) || true
if [[ -n "$ws_status" ]]; then
    ok "WebSocket: 101 handshake successful"
else
    fail "WebSocket: handshake failed"
fi

# ─── 6. .env Integrity ─────────��──────────────────────────────────────
log "6. Checking .env configuration..."
if [[ -f "${ENV_PATH}" ]]; then
    ok "~/.cloudcli/.env: exists"
    # Check critical fields
    has_platform=$(grep -c "VITE_IS_PLATFORM=true" "${ENV_PATH}" ) || true
    if [[ "$has_platform" -ge 1 ]]; then
        ok "VITE_IS_PLATFORM=true: configured"
    else
        fail "VITE_IS_PLATFORM=true: NOT set"
    fi
    has_port=$(grep -c "SERVER_PORT=${PORT}" "${ENV_PATH}" ) || true
    if [[ "$has_port" -ge 1 ]]; then
        ok "SERVER_PORT=${PORT}: configured"
    else
        fail "SERVER_PORT=${PORT}: NOT set"
    fi
else
    fail "~/.cloudcli/.env: NOT found"
fi

# Check symlink
if [[ -L "${PROJECT_ENV}" ]]; then
    symlink_target=$(readlink "${PROJECT_ENV}" )
    if [[ "$symlink_target" == "${ENV_PATH}" ]]; then
        ok "Project .env: symlink → ~/.cloudcli/.env"
    else
        fail "Project .env: symlink points to wrong target (${symlink_target})"
    fi
elif [[ -f "${PROJECT_ENV}" ]]; then
    warn "Project .env: regular file (not symlink) — should link to ~/.cloudcli/.env"
else
    fail "Project .env: NOT found"
fi

# ─── 7. Git Repository ────────────────────────────────────────────────
log "7. Checking git repository..."
git_dir="/home/opc2_uname/cc_ps/cc_webui/.git"
if [[ -d "${git_dir}" ]]; then
    ok "Git repository: initialized"
    git_log=$(git -C /home/opc2_uname/cc_ps/cc_webui log --oneline -1 2>&1) || true
    ok "Git version: ${git_log}"
    git_branch=$(git -C /home/opc2_uname/cc_ps/cc_webui branch --show-current 2>&1) || true
    ok "Git branch: ${git_branch}"
else
    fail "Git repository: NOT found"
fi

# ─── 8. Build Artifacts ────────────────────────────────────────────────
log "8. Checking build artifacts..."
dist_dir="/home/opc2_uname/cc_ps/cc_webui/dist"
dist_server_dir="/home/opc2_uname/cc_ps/cc_webui/dist-server/server"
if [[ -f "${dist_server_dir}/index.js" ]]; then
    ok "dist-server/server/index.js: exists"
else
    fail "dist-server/server/index.js: NOT found — run npm run build"
fi
if [[ -d "${dist_dir}" ]] && [[ -n "$(ls -A ${dist_dir}/assets/ 2>/dev/null)" ]]; then
    ok "dist/assets/: frontend bundle exists"
else
    fail "dist/assets/: NOT found — run npm run build"
fi

# ─── Summary ────────────────────────────────────────────────────────────
echo ""
echo "================================================="
echo -e " Health Check Results:  ${GREEN}${PASS} passed${NC}  ${RED}${FAIL} failed${NC}"
echo "================================================="
if [[ $FAIL -eq 0 ]]; then
    echo -e "${GREEN}All checks passed — CloudCLI WebUI is fully operational${NC}"
    exit 0
else
    echo -e "${RED}${FAIL} checks failed — investigate and fix before proceeding${NC}"
    exit 1
fi
