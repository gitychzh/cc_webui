#!/usr/bin/env bash
#
# CloudCLI WebUI Remote Deploy Script
# Usage:
#   ./scripts/deploy-remote.sh              # Full upgrade: push, pull, build, restart, verify
#   ./scripts/deploy-remote.sh --check      # Check remote status only (no changes)
#   ./scripts/deploy-remote.sh --rollback   # Rollback to previous commit
#
# Architecture: 3-layer separation
#   Layer 1 - Code:   git-managed repo at ~/cc_ps/cc_webui (pull/push updates)
#   Layer 2 - Config: ~/.cloudcli/.env (independent, survives upgrades)
#   Layer 3 - Data:   ~/.cloudcli/auth.db + logs (independent, survives upgrades)
#

set -euo pipefail

# ─── Configuration ───────────────────────────────────────────────────────────
SSH_HOST="${SSH_HOST:-opc2sname-tailscale}"        # SSH alias (see ~/.ssh/config)
SSH_CMD="ssh ${SSH_HOST}"
REMOTE_DIR="/home/opc2_uname/cc_ps/cc_webui"
REMOTE_ENV="/home/opc2_uname/.cloudcli/.env"
BRANCH="feature_cc_webui"
SERVICE="cloudcli"
PORT=3001
HEALTH_URL="http://100.109.57.26:${PORT}/health"
# ──────────────────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${BLUE}[DEPLOY]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ─── Check Mode ──────────────────────────────────────────────────────────────
check_remote() {
    log "Checking remote CloudCLI status..."

    # Service status
    local svc_status
    svc_status=$(${SSH_CMD} "systemctl is-active ${SERVICE}" 2>&1) || true
    if [[ "$svc_status" == "active" ]]; then
        ok "Service ${SERVICE}: active (running)"
    else
        warn "Service ${SERVICE}: ${svc_status}"
    fi

    # Enabled?
    local svc_enabled
    svc_enabled=$(${SSH_CMD} "systemctl is-enabled ${SERVICE}" 2>&1) || true
    if [[ "$svc_enabled" == "enabled" ]]; then
        ok "Service ${SERVICE}: enabled (auto-start)"
    else
        warn "Service ${SERVICE}: ${svc_enabled} (NOT auto-start)"
    fi

    # Port listening
    local port_check
    port_check=$(${SSH_CMD} "ss -tlnp | grep ${PORT}" 2>&1) || true
    if [[ -n "$port_check" ]]; then
        ok "Port ${PORT}: listening"
    else
        warn "Port ${PORT}: NOT listening"
    fi

    # Health endpoint
    local health
    health=$(curl -sf "${HEALTH_URL}" 2>&1) || true
    if [[ -n "$health" ]]; then
        ok "Health API: ${health}"
    else
        warn "Health API: unreachable"
    fi

    # Git version
    local git_log
    git_log=$(${SSH_CMD} "cd ${REMOTE_DIR} && git log --oneline -1 2>/dev/null" 2>&1) || true
    if [[ -n "$git_log" ]]; then
        ok "Git version: ${git_log}"
    else
        warn "No git repository"
    fi

    # .env location
    local env_check
    env_check=$(${SSH_CMD} "ls -la ${REMOTE_DIR}/.env 2>&1" 2>&1) || true
    ok ".env: ${env_check}"

    # Disk space
    local disk
    disk=$(${SSH_CMD} "df -h /home/opc2_uname/ | tail -1" 2>&1)
    ok "Disk: ${disk}"

    log "Check complete."
}

# ─── Rollback Mode ──────────────────────────────────────────────────────────
rollback_remote() {
    log "Rolling back to previous commit..."

    # Get current and previous commit
    local current_commit
    current_commit=$(${SSH_CMD} "cd ${REMOTE_DIR} && git rev-parse HEAD" 2>&1)
    ok "Current: ${current_commit}"

    local prev_commit
    prev_commit=$(${SSH_CMD} "cd ${REMOTE_DIR} && git rev-parse HEAD~1" 2>&1)
    ok "Previous: ${prev_commit}"

    # Reset to previous commit
    ${SSH_CMD} "cd ${REMOTE_DIR} && git reset --hard HEAD~1" 2>&1
    ok "Git reset to: ${prev_commit}"

    # Rebuild
    log "Rebuilding from rollback version..."
    ${SSH_CMD} "cd ${REMOTE_DIR} && npm run build 2>&1 | tail -5"

    # Restart service
    ${SSH_CMD} "sudo systemctl restart ${SERVICE}" 2>&1
    sleep 3

    # Verify
    local health
    health=$(curl -sf "${HEALTH_URL}" 2>&1) || true
    if [[ -n "$health" ]]; then
        ok "Rollback successful! Health: ${health}"
    else
        err "Rollback failed — service not responding on ${HEALTH_URL}"
    fi
}

# ─── Upgrade Mode (default) ────────────────────────────────────────────────
upgrade_remote() {
    log "=== CloudCLI Remote Upgrade ==="

    # Step 1: Push local changes to GitHub
    log "Step 1: Pushing local changes to GitHub..."
    local local_branch
    local_branch=$(git branch --show-current 2>&1)
    if [[ "$local_branch" != "${BRANCH}" ]]; then
        warn "Local branch is '${local_branch}', expected '${BRANCH}'"
        warn "Continuing anyway — make sure your changes are pushed"
    fi

    local unpushed
    unpushed=$(git log origin/${BRANCH}..HEAD --oneline 2>&1) || true
    if [[ -n "$unpushed" ]]; then
        log "Unpushed commits found, pushing..."
        git push origin ${BRANCH} 2>&1 || err "Failed to push to origin"
        ok "Pushed to origin/${BRANCH}"
    else
        ok "No unpushed commits — remote is up to date"
    fi

    # Step 2: Pull on remote
    log "Step 2: Pulling latest code on remote..."
    ${SSH_CMD} "cd ${REMOTE_DIR} && git stash --include-untracked 2>/dev/null || true"
    ${SSH_CMD} "cd ${REMOTE_DIR} && git pull origin ${BRANCH} 2>&1"
    ok "Remote code updated"

    # Step 3: Install dependencies
    log "Step 3: Installing dependencies..."
    ${SSH_CMD} "cd ${REMOTE_DIR} && npm install 2>&1 | tail -3"
    ok "Dependencies installed"

    # Step 4: Build
    log "Step 4: Building..."
    ${SSH_CMD} "cd ${REMOTE_DIR} && npm run build 2>&1 | tail -5"
    ok "Build complete"

    # Step 5: Restart service
    log "Step 5: Restarting service..."
    ${SSH_CMD} "sudo systemctl restart ${SERVICE}" 2>&1
    sleep 4

    # Step 6: Health verification
    log "Step 6: Health verification..."
    local health
    health=$(curl -sf "${HEALTH_URL}" 2>&1) || true
    if [[ -n "$health" ]]; then
        ok "Service healthy: ${health}"
    else
        err "Service NOT responding — rollback recommended: ./scripts/deploy-remote.sh --rollback"
    fi

    # Step 7: Git version confirmation
    local git_log
    git_log=$(${SSH_CMD} "cd ${REMOTE_DIR} && git log --oneline -1" 2>&1)
    ok "Deployed version: ${git_log}"

    ok "=== Upgrade Complete ==="
}

# ─── Main ────────────────────────────────────────────────────────────────────
case "${1:-}" in
    --check|-c)
        check_remote
        ;;
    --rollback|-r)
        rollback_remote
        ;;
    --help|-h)
        echo "Usage: $0 [--check|--rollback|--help]"
        echo "  (default)  Full upgrade: push → pull → install → build → restart → verify"
        echo "  --check    Check remote status only"
        echo "  --rollback Rollback to previous git commit"
        echo "  --help     Show this help"
        ;;
    *)
        upgrade_remote
        ;;
esac
