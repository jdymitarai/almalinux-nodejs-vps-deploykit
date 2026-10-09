#!/usr/bin/env bash
# ==============================================================================
# AlmaLinux 9 / RHEL VPS Node.js Automated Deployment Script
# Repository: almalinux-nodejs-vps-deploykit
# Description: Idempotent, zero-downtime atomic deployment pipeline for Node.js
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

# Script Directory and Base Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="${APP_NAME:-nodeapp}"
APP_USER="${APP_USER:-nodeapp}"
APP_GROUP="${APP_GROUP:-nodeapp}"
DEPLOY_ROOT="${DEPLOY_ROOT:-/opt/nodeapp}"
RELEASES_DIR="${DEPLOY_ROOT}/releases"
SHARED_DIR="${DEPLOY_ROOT}/shared"
CURRENT_LINK="${DEPLOY_ROOT}/current"
PREVIOUS_LINK="${DEPLOY_ROOT}/previous"
SYSTEMD_SERVICE="app.service"
SYSTEMD_FILE="/etc/systemd/system/${SYSTEMD_SERVICE}"
APACHE_CONF_FILE="/etc/httpd/conf.d/app.conf"
KEEP_RELEASES="${KEEP_RELEASES:-5}"
PORT="${PORT:-3000}"
HEALTHCHECK_RETRIES="${HEALTHCHECK_RETRIES:-10}"
HEALTHCHECK_DELAY="${HEALTHCHECK_DELAY:-2}"

# Source app directory to deploy (defaults to sample-app if current dir doesn't contain package.json)
if [[ -f "${SCRIPT_DIR}/package.json" ]]; then
    SOURCE_APP_DIR="${SCRIPT_DIR}"
elif [[ -d "${SCRIPT_DIR}/sample-app" && -f "${SCRIPT_DIR}/sample-app/package.json" ]]; then
    SOURCE_APP_DIR="${SCRIPT_DIR}/sample-app"
else
    SOURCE_APP_DIR="${SCRIPT_DIR}"
fi

# Color Palette for CLI output
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_BLUE='\033[0;34m'
C_CYAN='\033[0;36m'

log_info() {
    echo -e "${C_CYAN}[$(date '+%Y-%m-%d %H:%M:%S')] [INFO]${C_RESET} $*"
}

log_warn() {
    echo -e "${C_YELLOW}[$(date '+%Y-%m-%d %H:%M:%S')] [WARN]${C_RESET} $*"
}

log_error() {
    echo -e "${C_RED}[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR]${C_RESET} $*" >&2
}

log_success() {
    echo -e "${C_GREEN}[$(date '+%Y-%m-%d %H:%M:%S')] [SUCCESS]${C_RESET} $*"
}

# Trap unexpected errors
trap_error() {
    local exit_code=$?
    local line_no=$1
    log_error "Deployment failed at line ${line_no} with exit code ${exit_code}."
    exit "${exit_code}"
}
trap 'trap_error ${LINENO}' ERR

# ==============================================================================
# Phase 1: Pre-flight Verification
# ==============================================================================
preflight_checks() {
    log_info "Running pre-flight environment checks..."

    # Check root privileges
    if [[ "${EUID}" -ne 0 ]]; then
        log_error "This script must be executed as root or via sudo."
        exit 1
    fi

    # Verify OS distribution
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        log_info "Detected OS: ${NAME:-Linux} ${VERSION_ID:-Unknown}"
        case "${ID:-linux}" in
            almalinux|rocky|rhel|centos|fedora)
                log_info "Operating system compatibility confirmed."
                ;;
            *)
                log_warn "Distribution '${ID}' is not an explicitly certified RHEL/AlmaLinux derivative. Proceeding with caution."
                ;;
        esac
    else
        log_warn "/etc/os-release not found. Unable to accurately verify distribution."
    fi

    # Verify Node.js LTS
    if ! command -v node >/dev/null 2>&1; then
        log_error "Node.js executable not found in PATH."
        log_error "On AlmaLinux 9, install Node.js 20 LTS using:"
        log_error "  sudo dnf module enable nodejs:20 -y && sudo dnf install -y nodejs"
        exit 1
    fi
    local node_ver
    node_ver="$(node -v)"
    log_info "Node.js detected: ${node_ver}"

    # Verify npm
    if ! command -v npm >/dev/null 2>&1; then
        log_error "npm executable not found in PATH."
        exit 1
    fi
    log_info "npm detected: $(npm -v)"

    # Verify MariaDB / MySQL client or service availability
    if command -v mariadb >/dev/null 2>&1 || command -v mysql >/dev/null 2>&1; then
        log_info "MariaDB/MySQL client detected."
    else
        log_warn "MariaDB/MySQL client not installed. Install via: dnf install -y mariadb-server mariadb"
    fi

    # Verify Apache (httpd)
    if command -v httpd >/dev/null 2>&1; then
        log_info "Apache (httpd) web server detected."
    else
        log_warn "httpd binary not found. Install via: dnf install -y httpd mod_ssl"
    fi

    # Check SELinux and configure httpd network connectivity if enforcing
    if command -v getenforce >/dev/null 2>&1; then
        local selinux_mode
        selinux_mode="$(getenforce)"
        log_info "SELinux mode: ${selinux_mode}"
        if [[ "${selinux_mode}" =~ ^(Enforcing|Permissive)$ ]]; then
            log_info "Ensuring SELinux boolean 'httpd_can_network_connect' is enabled for reverse proxying..."
            if command -v setsebool >/dev/null 2>&1; then
                setsebool -P httpd_can_network_connect 1 || log_warn "Failed to set httpd_can_network_connect boolean."
            fi
        fi
    fi

    # Check Firewalld status
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active --quiet firewalld; then
        log_info "Firewalld is active. Verifying HTTP/HTTPS service ports..."
        firewall-cmd --permanent --add-service=http --add-service=https >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi

    log_success "Pre-flight checks completed successfully."
}

# ==============================================================================
# Phase 2: Dedicated System User & Directory Isolation
# ==============================================================================
setup_system_user_and_dirs() {
    log_info "Configuring dedicated system user '${APP_USER}' and isolated filesystem..."

    # Ensure system group exists
    if ! getent group "${APP_GROUP}" >/dev/null 2>&1; then
        groupadd --system "${APP_GROUP}"
        log_info "Created system group '${APP_GROUP}'."
    fi

    # Ensure system user exists
    if ! id -u "${APP_USER}" >/dev/null 2>&1; then
        useradd --system \
            --gid "${APP_GROUP}" \
            --home-dir "${DEPLOY_ROOT}" \
            --no-create-home \
            --shell /sbin/nologin \
            --comment "Node.js Application Service Account" \
            "${APP_USER}"
        log_info "Created dedicated system user '${APP_USER}'."
    fi

    # Create directory structure
    mkdir -p "${RELEASES_DIR}"
    mkdir -p "${SHARED_DIR}"
    mkdir -p "${SHARED_DIR}/logs"

    # Enforce strict 750 directory permission isolation
    chmod 750 "${DEPLOY_ROOT}"
    chmod 750 "${RELEASES_DIR}"
    chmod 750 "${SHARED_DIR}"
    chmod 750 "${SHARED_DIR}/logs"

    # Ensure app owns deployment root
    chown -R "${APP_USER}:${APP_GROUP}" "${DEPLOY_ROOT}"
    log_success "Directory structure created with chmod 750 isolation."
}

# ==============================================================================
# Phase 3: Secure Environment Configuration (.env)
# ==============================================================================
setup_environment() {
    local env_file="${SHARED_DIR}/.env"
    log_info "Checking shared environment file at ${env_file}..."

    if [[ ! -f "${env_file}" ]]; then
        if [[ -f "${SCRIPT_DIR}/.env.example" ]]; then
            log_warn "${env_file} does not exist. Initializing from .env.example template."
            cp "${SCRIPT_DIR}/.env.example" "${env_file}"
        else
            log_warn "Creating default production .env file."
            cat > "${env_file}" <<EOF
# Production Environment Variables
NODE_ENV=production
PORT=${PORT}
HOST=127.0.0.1
DB_HOST=127.0.0.1
DB_PORT=3306
DB_NAME=nodeapp_db
DB_USER=nodeapp_user
DB_PASSWORD=change_this_secure_password
LOG_LEVEL=info
EOF
        fi
        log_warn "PLEASE REVIEW AND UPDATE SECRETS IN: ${env_file}"
    fi

    # Enforce strict 600 permissions on .env
    chmod 600 "${env_file}"
    chown "${APP_USER}:${APP_GROUP}" "${env_file}"
    log_success "Environment security confirmed (chmod 600 owned by ${APP_USER})."
}

# ==============================================================================
# Phase 4: Atomic Release Packaging & Dependency Installation
# ==============================================================================
deploy_release() {
    local timestamp
    timestamp="$(date +%Y%m%d%H%M%S)"
    local release_dir="${RELEASES_DIR}/${timestamp}"
    log_info "Starting atomic release: ${timestamp}"
    log_info "Target release directory: ${release_dir}"

    mkdir -p "${release_dir}"

    # Copy application source files excluding git metadata, logs, and development artifacts
    log_info "Copying application source from ${SOURCE_APP_DIR}..."
    if command -v rsync >/dev/null 2>&1; then
        rsync -a --exclude='.git' --exclude='node_modules' --exclude='.env' --exclude='logs' \
            "${SOURCE_APP_DIR}/" "${release_dir}/"
    else
        cp -a "${SOURCE_APP_DIR}/." "${release_dir}/"
        rm -rf "${release_dir}/.git" "${release_dir}/node_modules" "${release_dir}/.env" "${release_dir}/logs" 2>/dev/null || true
    fi

    # Symlink shared .env into release directory
    ln -sfn "${SHARED_DIR}/.env" "${release_dir}/.env"
    ln -sfn "${SHARED_DIR}/logs" "${release_dir}/logs"

    # Install production dependencies cleanly
    log_info "Installing production dependencies via npm ci..."
    cd "${release_dir}"
    if [[ -f "${release_dir}/package-lock.json" ]]; then
        su -s /bin/bash "${APP_USER}" -c "cd '${release_dir}' && npm ci --omit=dev --no-audit --no-fund"
    elif [[ -f "${release_dir}/package.json" ]]; then
        log_warn "package-lock.json not found; running npm install --omit=dev..."
        su -s /bin/bash "${APP_USER}" -c "cd '${release_dir}' && npm install --omit=dev --no-audit --no-fund"
    fi

    # Fix ownership of entire release directory
    chown -R "${APP_USER}:${APP_GROUP}" "${release_dir}"

    # Preserve current release pointer for atomic rollback
    if [[ -L "${CURRENT_LINK}" ]]; then
        local previous_target
        previous_target="$(readlink -f "${CURRENT_LINK}" || true)"
        if [[ -d "${previous_target}" ]]; then
            ln -sfn "${previous_target}" "${PREVIOUS_LINK}"
            log_info "Updated rollback target -> ${previous_target}"
        fi
    fi

    # Switch current symlink atomically to new release
    ln -sfn "${release_dir}" "${CURRENT_LINK}"
    log_success "Active release symlink switched to: ${release_dir}"
}

# ==============================================================================
# Phase 5: Systemd & Apache Service Management
# ==============================================================================
configure_and_restart_services() {
    log_info "Synchronizing systemd and web server service units..."

    # Deploy systemd service unit file if present
    if [[ -f "${SCRIPT_DIR}/app.service" ]]; then
        log_info "Installing systemd unit file to ${SYSTEMD_FILE}..."
        cp "${SCRIPT_DIR}/app.service" "${SYSTEMD_FILE}"
        chmod 644 "${SYSTEMD_FILE}"
        systemctl daemon-reload
        systemctl enable "${SYSTEMD_SERVICE}"
    fi

    # Deploy Apache reverse proxy configuration if present
    if [[ -f "${SCRIPT_DIR}/app.conf" && -d "/etc/httpd/conf.d" ]]; then
        if [[ ! -f "${APACHE_CONF_FILE}" ]]; then
            log_info "Deploying Apache reverse proxy configuration to ${APACHE_CONF_FILE}..."
            cp "${SCRIPT_DIR}/app.conf" "${APACHE_CONF_FILE}"
            chmod 644 "${APACHE_CONF_FILE}"
        else
            log_info "Existing Apache configuration found at ${APACHE_CONF_FILE} (skipping overwrite to protect domain SSL customisations)."
        fi

        # Validate Apache configuration syntax
        if command -v apachectl >/dev/null 2>&1; then
            log_info "Validating Apache configuration syntax..."
            if apachectl configtest; then
                if systemctl is-active --quiet httpd; then
                    systemctl reload httpd
                    log_info "Apache (httpd) reloaded."
                else
                    systemctl enable --now httpd
                    log_info "Apache (httpd) enabled and started."
                fi
            else
                log_warn "Apache syntax check reported warnings/errors. Please review apachectl configtest."
            fi
        fi
    fi

    # Restart Node.js application service
    log_info "Restarting ${SYSTEMD_SERVICE}..."
    systemctl restart "${SYSTEMD_SERVICE}"
    log_success "Service ${SYSTEMD_SERVICE} restarted successfully."
}

# ==============================================================================
# Phase 6: Post-Deployment Health Check & Self-Healing Rollback
# ==============================================================================
verify_and_guard() {
    log_info "Executing post-deployment health verification..."

    local healthcheck_bin="${SCRIPT_DIR}/healthcheck.sh"
    local rollback_bin="${SCRIPT_DIR}/rollback.sh"

    if [[ -x "${healthcheck_bin}" ]]; then
        if "${healthcheck_bin}" --port "${PORT}" --retries "${HEALTHCHECK_RETRIES}" --delay "${HEALTHCHECK_DELAY}"; then
            log_success "Health check verified! Deployment is stable and healthy."
        else
            log_error "Post-deployment health verification failed!"
            if [[ -x "${rollback_bin}" ]]; then
                log_warn "Invoking automated rollback pipeline..."
                "${rollback_bin}"
            else
                log_error "Rollback script (${rollback_bin}) not executable. Manual intervention required!"
            fi
            exit 1
        fi
    else
        log_warn "Healthcheck script (${healthcheck_bin}) not found or not executable. Falling back to internal probe..."
        local healthy=0
        for ((i=1; i<=HEALTHCHECK_RETRIES; i++)); do
            if curl -s -f -m 3 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1; then
                healthy=1
                break
            fi
            sleep "${HEALTHCHECK_DELAY}"
        done

        if [[ "${healthy}" -eq 1 ]]; then
            log_success "Internal healthcheck probe succeeded on port ${PORT}."
        else
            log_error "Internal healthcheck probe failed on port ${PORT}."
            exit 1
        fi
    fi
}

# ==============================================================================
# Phase 7: Retention Pruning (Keep last N releases)
# ==============================================================================
cleanup_old_releases() {
    log_info "Pruning stale releases (keeping last ${KEEP_RELEASES})..."
    cd "${RELEASES_DIR}"

    local count
    count="$(find . -maxdepth 1 -mindepth 1 -type d | wc -l)"
    if (( count > KEEP_RELEASES )); then
        local to_remove
        to_remove=$(( count - KEEP_RELEASES ))
        log_info "Removing ${to_remove} obsolete release(s)..."
        # Sort oldest first and remove
        find . -maxdepth 1 -mindepth 1 -type d -printf '%T@ %p\n' \
            | sort -n \
            | head -n "${to_remove}" \
            | awk '{print $2}' \
            | while read -r old_release; do
                local current_target
                current_target="$(readlink -f "${CURRENT_LINK}" || true)"
                local previous_target
                previous_target="$(readlink -f "${PREVIOUS_LINK}" || true)"
                local resolved_old
                resolved_old="$(readlink -f "${old_release}" || true)"

                if [[ "${resolved_old}" == "${current_target}" || "${resolved_old}" == "${previous_target}" ]]; then
                    log_info "Skipping ${old_release} (currently active or designated rollback target)."
                else
                    log_info "Pruning old release: ${old_release}"
                    rm -rf "${old_release}"
                fi
            done
    else
        log_info "Release count (${count}) is within retention limit (${KEEP_RELEASES})."
    fi
    log_success "Release directory cleanup completed."
}

# ==============================================================================
# Main Orchestrator
# ==============================================================================
main() {
    log_info "=========================================================="
    log_info " AlmaLinux 9 Node.js VPS DeployKit - Starting Deployment"
    log_info "=========================================================="

    preflight_checks
    setup_system_user_and_dirs
    setup_environment
    deploy_release
    configure_and_restart_services
    verify_and_guard
    cleanup_old_releases

    log_info "=========================================================="
    log_success " DEPLOYMENT FINISHED SUCCESSFULLY"
    log_info " App Directory: ${CURRENT_LINK}"
    log_info " Service Status: systemctl status ${SYSTEMD_SERVICE}"
    log_info " Journal Logs: journalctl -u ${SYSTEMD_SERVICE} -f"
    log_info "=========================================================="
}

main "$@"
