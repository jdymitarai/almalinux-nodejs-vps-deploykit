#!/usr/bin/env bash
# ==============================================================================
# AlmaLinux 9 / RHEL VPS Node.js Automated Rollback Script
# Repository: almalinux-nodejs-vps-deploykit
# Description: Instant zero-downtime atomic rollback to previous stable release
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="${APP_NAME:-nodeapp}"
APP_USER="${APP_USER:-nodeapp}"
DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/nodeapp}"
SHARED_DIR="${DEPLOY_ROOT}/shared"
CURRENT_LINK="${DEPLOY_ROOT}/current"
PREVIOUS_LINK="${DEPLOY_ROOT}/previous"
SYSTEMD_SERVICE="app.service"
LOG_FILE="${SHARED_DIR}/logs/deploy.log"
PORT="${PORT:-3000}"

C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[0;36m'

log_msg() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    
    case "${level}" in
        INFO)    echo -e "${C_CYAN}[${timestamp}] [INFO]${C_RESET} ${msg}" ;;
        WARN)    echo -e "${C_YELLOW}[${timestamp}] [WARN]${C_RESET} ${msg}" ;;
        ERROR)   echo -e "${C_RED}[${timestamp}] [ERROR]${C_RESET} ${msg}" >&2 ;;
        SUCCESS) echo -e "${C_GREEN}[${timestamp}] [SUCCESS]${C_RESET} ${msg}" ;;
    esac

    # Append to log file if directory exists
    if [[ -d "${SHARED_DIR}/logs" ]]; then
        echo "[${timestamp}] [ROLLBACK] [${level}] ${msg}" >> "${LOG_FILE}" 2>/dev/null || true
    fi
}

main() {
    log_msg INFO "Initiating atomic rollback procedure..."

    if [[ "${EUID}" -ne 0 ]]; then
        log_msg ERROR "Rollback script must be executed as root or via sudo."
        exit 1
    fi

    # Verify previous link exists
    if [[ ! -L "${PREVIOUS_LINK}" ]]; then
        log_msg ERROR "Rollback target '${PREVIOUS_LINK}' does not exist. No previous release recorded."
        exit 1
    fi

    local target_release
    target_release="$(readlink -f "${PREVIOUS_LINK}" || true)"

    if [[ ! -d "${target_release}" ]]; then
        log_msg ERROR "Target release directory '${target_release}' does not exist on disk."
        exit 1
    fi

    local current_release
    current_release="$(readlink -f "${CURRENT_LINK}" || true)"
    log_msg INFO "Current failing release: ${current_release}"
    log_msg INFO "Rolling back to previous stable release: ${target_release}"

    # Atomic symlink swap using temporary link
    local tmp_link="${DEPLOY_ROOT}/current_tmp_$$"
    ln -sfn "${target_release}" "${tmp_link}"
    mv -Tf "${tmp_link}" "${CURRENT_LINK}"
    log_msg SUCCESS "Atomic symlink updated: ${CURRENT_LINK} -> ${target_release}"

    # Update previous link to point to the failing release (so operator can inspect or toggle back)
    if [[ -d "${current_release}" ]]; then
        ln -sfn "${current_release}" "${PREVIOUS_LINK}"
        log_msg INFO "Failing release retained in rollback history -> ${PREVIOUS_LINK}"
    fi

    # Restart application service
    log_msg INFO "Restarting systemd service: ${SYSTEMD_SERVICE}..."
    systemctl restart "${SYSTEMD_SERVICE}"

    # Perform healthcheck verification
    local healthcheck_bin="${SCRIPT_DIR}/healthcheck.sh"
    if [[ -x "${healthcheck_bin}" ]]; then
        log_msg INFO "Verifying service health after rollback..."
        if "${healthcheck_bin}" --port "${PORT}" --retries 10 --delay 2; then
            log_msg SUCCESS "Rollback verification passed! System restored to stable state."
        else
            log_msg ERROR "CRITICAL: Service failed health check even after rollback!"
            log_msg ERROR "Inspect application logs immediately: journalctl -u ${SYSTEMD_SERVICE} -n 50 --no-pager"
            exit 2
        fi
    else
        log_msg WARN "healthcheck.sh not found; verifying basic process status..."
        if systemctl is-active --quiet "${SYSTEMD_SERVICE}"; then
            log_msg SUCCESS "Service ${SYSTEMD_SERVICE} is active."
        else
            log_msg ERROR "Service ${SYSTEMD_SERVICE} failed to start after rollback."
            exit 2
        fi
    fi

    log_msg SUCCESS "Atomic rollback completed successfully."
}

main "$@"
