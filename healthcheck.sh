#!/usr/bin/env bash
# ==============================================================================
# AlmaLinux 9 / RHEL VPS Node.js Application Health Check Script
# Repository: almalinux-nodejs-vps-deploykit
# Description: Validates systemd unit state and verifies HTTP/JSON responsiveness
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# Default Configuration Parameters
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-3000}"
PATH_URI="${PATH_URI:-/health}"
RETRIES="${RETRIES:-5}"
DELAY="${DELAY:-2}"
TIMEOUT="${TIMEOUT:-3}"
SERVICE_NAME="${SERVICE_NAME:-app.service}"
CHECK_SERVICE="${CHECK_SERVICE:-auto}" # auto | yes | no

# ANSI Color Output
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[0;36m'

log_info() {
    echo -e "${C_CYAN}[HEALTHCHECK] [INFO]${C_RESET} $*"
}

log_warn() {
    echo -e "${C_YELLOW}[HEALTHCHECK] [WARN]${C_RESET} $*"
}

log_error() {
    echo -e "${C_RED}[HEALTHCHECK] [ERROR]${C_RESET} $*" >&2
}

log_success() {
    echo -e "${C_GREEN}[HEALTHCHECK] [PASS]${C_RESET} $*"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -h, --host HOST          Target host address (default: 127.0.0.1)
  -p, --port PORT          Target port (default: 3000)
  -u, --path PATH          Health endpoint path (default: /health)
  -r, --retries NUM        Number of retry attempts (default: 5)
  -d, --delay SECONDS      Delay between retries in seconds (default: 2)
  -t, --timeout SECONDS    Curl connection timeout in seconds (default: 3)
  -s, --service NAME       Systemd service unit name (default: app.service)
  --no-service-check       Bypass systemd unit state verification
  --help                   Display this help message
EOF
    exit 0
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -h|--host) HOST="$2"; shift 2 ;;
            -p|--port) PORT="$2"; shift 2 ;;
            -u|--path) PATH_URI="$2"; shift 2 ;;
            -r|--retries) RETRIES="$2"; shift 2 ;;
            -d|--delay) DELAY="$2"; shift 2 ;;
            -t|--timeout) TIMEOUT="$2"; shift 2 ;;
            -s|--service) SERVICE_NAME="$2"; shift 2 ;;
            --no-service-check) CHECK_SERVICE="no"; shift ;;
            --help) usage ;;
            *) echo "Unknown option: $1" >&2; exit 1 ;;
        esac
    done
}

verify_systemd_service() {
    if [[ "${CHECK_SERVICE}" == "no" ]]; then
        log_info "Systemd service check explicitly bypassed via flag."
        return 0
    fi

    if ! command -v systemctl >/dev/null 2>&1; then
        log_info "systemctl not available on this host; skipping service verification."
        return 0
    fi

    # Check if systemd unit exists or is known to systemd
    if systemctl cat "${SERVICE_NAME}" >/dev/null 2>&1 || [[ -f "/etc/systemd/system/${SERVICE_NAME}" ]]; then
        log_info "Verifying systemd unit status for '${SERVICE_NAME}'..."
        if systemctl is-active --quiet "${SERVICE_NAME}"; then
            log_success "Systemd service '${SERVICE_NAME}' is active (running)."
        else
            local status_desc
            status_desc="$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || echo "inactive")"
            log_error "Systemd service '${SERVICE_NAME}' is not running (State: ${status_desc})."
            systemctl status "${SERVICE_NAME}" --no-pager -n 15 || true
            return 1
        fi
    else
        log_info "Systemd unit '${SERVICE_NAME}' not found; skipping service check."
    fi
    return 0
}

verify_http_endpoint() {
    local target_url="http://${HOST}:${PORT}${PATH_URI}"
    log_info "Probing health endpoint: ${target_url} (Max attempts: ${RETRIES}, Timeout: ${TIMEOUT}s)..."

    local attempt=1
    while [[ ${attempt} -le ${RETRIES} ]]; do
        log_info "Attempt ${attempt}/${RETRIES}..."
        
        # Probe HTTP endpoint capturing body and HTTP status code
        local http_response
        http_response="$(curl -s -S -m "${TIMEOUT}" -w "\n%{http_code}" "${target_url}" 2>/dev/null || printf "\n000")"
        
        local http_code
        http_code="$(echo "${http_response}" | tail -n1)"
        local response_body
        response_body="$(echo "${http_response}" | sed '$d')"

        if [[ "${http_code}" == "200" ]]; then
            log_success "HTTP status 200 OK received from ${target_url}"
            if [[ -n "${response_body}" ]]; then
                log_info "Response payload: ${response_body}"
            fi
            return 0
        else
            log_warn "Health check attempt ${attempt} returned status: ${http_code}"
            if [[ ${attempt} -lt ${RETRIES} ]]; then
                sleep "${DELAY}"
            fi
        fi
        attempt=$((attempt + 1))
    done

    log_error "CRITICAL: Health check failed after ${RETRIES} attempts on ${target_url}."
    return 1
}

main() {
    parse_arguments "$@"

    if ! verify_systemd_service; then
        exit 1
    fi

    if ! verify_http_endpoint; then
        exit 1
    fi

    log_success "All health verification checks passed successfully."
}

main "$@"
