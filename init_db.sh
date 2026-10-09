#!/usr/bin/env bash
# ==============================================================================
# AlmaLinux 9 / RHEL VPS MariaDB Secure Database Initialization
# Repository: almalinux-nodejs-vps-deploykit
# Description: Idempotent database, user, privilege, and schema provisioning
# ==============================================================================

set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/.env"
SCHEMA_FILE="${SCRIPT_DIR}/schema.sql"

# Check if production shared .env exists
if [[ -f "/opt/nodeapp/shared/.env" ]]; then
    ENV_FILE="/opt/nodeapp/shared/.env"
fi

# Color Palette
C_RESET='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[1;33m'
C_CYAN='\033[0;36m'

log_info() {
    echo -e "${C_CYAN}[DB-INIT] [INFO]${C_RESET} $*"
}

log_warn() {
    echo -e "${C_YELLOW}[DB-INIT] [WARN]${C_RESET} $*"
}

log_error() {
    echo -e "${C_RED}[DB-INIT] [ERROR]${C_RESET} $*" >&2
}

log_success() {
    echo -e "${C_GREEN}[DB-INIT] [SUCCESS]${C_RESET} $*"
}

usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Options:
  -e, --env-file PATH      Path to .env configuration file (default: ${ENV_FILE})
  -s, --schema PATH        Path to schema SQL file (default: ${SCHEMA_FILE})
  -d, --db-name NAME       Target database name (overrides .env)
  -u, --db-user USER       Target database username (overrides .env)
  -p, --db-pass PASS       Target database user password (overrides .env)
  --root-user USER         MariaDB administrative user (default: root)
  --root-pass PASS         MariaDB administrative password (leave blank for socket auth)
  --help                   Display this help message
EOF
    exit 0
}

# Administrative connection parameters
MARIADB_ROOT_USER="root"
MARIADB_ROOT_PASS=""
OVERRIDE_DB_NAME=""
OVERRIDE_DB_USER=""
OVERRIDE_DB_PASS=""

# Parse Arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -e|--env-file) ENV_FILE="$2"; shift 2 ;;
        -s|--schema) SCHEMA_FILE="$2"; shift 2 ;;
        -d|--db-name) OVERRIDE_DB_NAME="$2"; shift 2 ;;
        -u|--db-user) OVERRIDE_DB_USER="$2"; shift 2 ;;
        -p|--db-pass) OVERRIDE_DB_PASS="$2"; shift 2 ;;
        --root-user) MARIADB_ROOT_USER="$2"; shift 2 ;;
        --root-pass) MARIADB_ROOT_PASS="$2"; shift 2 ;;
        --help) usage ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Load environment configuration if available
if [[ -f "${ENV_FILE}" ]]; then
    log_info "Loading database credentials from ${ENV_FILE}..."
    # shellcheck disable=SC1090
    set -a
    source "${ENV_FILE}"
    set +a
fi

DB_NAME="${OVERRIDE_DB_NAME:-${DB_NAME:-nodeapp_db}}"
DB_USER="${OVERRIDE_DB_USER:-${DB_USER:-nodeapp_user}}"
DB_PASSWORD="${OVERRIDE_DB_PASS:-${DB_PASSWORD:-}}"

if [[ -z "${DB_PASSWORD}" ]]; then
    log_error "DB_PASSWORD is empty! Please set DB_PASSWORD in ${ENV_FILE} or pass --db-pass."
    exit 1
fi

# Locate MariaDB / MySQL client binary
DB_CLIENT=""
if command -v mariadb >/dev/null 2>&1; then
    DB_CLIENT="mariadb"
elif command -v mysql >/dev/null 2>&1; then
    DB_CLIENT="mysql"
else
    log_error "Neither 'mariadb' nor 'mysql' client command is available."
    exit 1
fi

# Build root command invocation
ROOT_CMD=("${DB_CLIENT}" "-u" "${MARIADB_ROOT_USER}")
if [[ -n "${MARIADB_ROOT_PASS}" ]]; then
    ROOT_CMD+=("-p${MARIADB_ROOT_PASS}")
fi

run_admin_sql() {
    local sql_query="$1"
    "${ROOT_CMD[@]}" -e "${sql_query}"
}

# 1. Verify MariaDB service
log_info "Checking MariaDB service status..."
if command -v systemctl >/dev/null 2>&1; then
    if systemctl is-active --quiet mariadb; then
        log_info "MariaDB service is active."
    else
        log_warn "MariaDB service is not active. Attempting to start service..."
        systemctl enable --now mariadb
    fi
fi

# 2. Enforce localhost binding configuration
HARDENING_CONF="/etc/my.cnf.d/99-local-binding.cnf"
if [[ -d "/etc/my.cnf.d" && ! -f "${HARDENING_CONF}" && "${EUID}" -eq 0 ]]; then
    log_info "Enforcing localhost/local socket binding in ${HARDENING_CONF}..."
    cat > "${HARDENING_CONF}" <<EOF
[mysqld]
# Ensure database does not listen on public network interfaces
bind-address = 127.0.0.1
local-infile = 0
symbolic-links = 0
EOF
    chmod 644 "${HARDENING_CONF}"
    log_info "Restarting MariaDB to apply security hardening..."
    systemctl restart mariadb
fi

# 3. Create isolated database and user with least privilege
log_info "Provisioning database '${DB_NAME}' with UTF8MB4 collation..."
run_admin_sql "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"

log_info "Provisioning isolated user '${DB_USER}'@'localhost'..."
run_admin_sql "CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"
run_admin_sql "ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASSWORD}';"

log_info "Applying least-privilege grants on '${DB_NAME}'.* to '${DB_USER}'@'localhost'..."
run_admin_sql "GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, INDEX, ALTER, REFERENCES, LOCK TABLES, EXECUTE ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';"
run_admin_sql "FLUSH PRIVILEGES;"
log_success "User permissions configured."

# 4. Import schema
if [[ -f "${SCHEMA_FILE}" ]]; then
    log_info "Applying schema migrations from ${SCHEMA_FILE}..."
    "${ROOT_CMD[@]}" "${DB_NAME}" < "${SCHEMA_FILE}"
    log_success "Schema applied successfully."
else
    log_warn "Schema file not found at ${SCHEMA_FILE}; skipping initial migration."
fi

# 5. Verify application credentials
log_info "Verifying application user authentication against database..."
if "${DB_CLIENT}" -u "${DB_USER}" "-p${DB_PASSWORD}" -h 127.0.0.1 -D "${DB_NAME}" -e "SELECT 1;" >/dev/null 2>&1; then
    log_success "Authentication verification successful! Application can connect to MariaDB."
else
    log_error "Connection test failed with application user credentials."
    exit 1
fi

log_success "Database initialization complete."
