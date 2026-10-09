# Production Deployment Runbook: Node.js on AlmaLinux 9 VPS

A battle-tested, end-to-end operational guide for deploying and maintaining production Node.js applications on AlmaLinux 9 / RHEL VPS systems (including Bluehost VPS, cPanel/WHM root shells, and bare-metal enterprise servers).

---

## 1. Architecture Overview

The deployment architecture utilizes an **Enterprise Dual-Tier Proxy & Isolation Model**:
1. **Edge Tier**: Apache 2.4 HTTP/2 reverse proxy handling TLS termination, WebSocket upgrades, HTTP compression, and canonical HTTPS redirection.
2. **Application Tier**: Node.js process managed by Systemd under a dedicated, unprivileged system user (`nodeapp`) with strict kernel sandboxing and directory permission isolation (`chmod 750`).
3. **Database Tier**: MariaDB 10.5/10.11 bound strictly to loopback (`127.0.0.1` and Unix socket) with application-isolated database credentials.

```
       [ Public Client Traffic: HTTPS / Port 443 ]
                           │
                           ▼
 ┌─────────────────────────────────────────────────────────────┐
 │ AlmaLinux 9 VPS (Host / OS Level)                           │
 │                                                             │
 │  ┌───────────────────────────────────────────────────────┐  │
 │  │ Firewalld (Ports: 22 [SSH], 80 [HTTP], 443 [HTTPS])    │  │
 │  │ Port 3000 is BLOCKED from external interfaces         │  │
 │  └──────────────────────────┬────────────────────────────┘  │
 │                             ▼                               │
 │  ┌───────────────────────────────────────────────────────┐  │
 │  │ Apache 2.4 (httpd) Reverse Proxy                      │  │
 │  │ - TLS 1.2 / TLS 1.3 Termination (Let's Encrypt)       │  │
 │  │ - mod_proxy & mod_proxy_wstunnel (WebSocket Upgrade)  │  │
 │  │ - mod_deflate Gzip Compression                        │  │
 │  │ - SELinux: httpd_can_network_connect = 1              │  │
 │  └──────────────────────────┬────────────────────────────┘  │
 │                             │ Loopback HTTP (127.0.0.1:3000)│
 │                             ▼                               │
 │  ┌───────────────────────────────────────────────────────┐  │
 │  │ Systemd Service: app.service                          │  │
 │  │ - Sandboxed User: nodeapp (chmod 750 isolation)       │  │
 │  │ - NoNewPrivileges=true, ProtectSystem=full            │  │
 │  │ - Auto-restart on crash (RestartSec=3s)               │  │
 │  │                                                       │  │
 │  │  /opt/nodeapp/                                        │  │
 │  │   ├── current -> releases/20261009120000              │  │
 │  │   ├── previous -> releases/20261009110000 (Rollback)  │  │
 │  │   ├── shared/ (.env [600], logs/)                     │  │
 │  │   └── releases/ (Atomic timestamped trees)            │  │
 │  └──────────────────────────┬────────────────────────────┘  │
 │                             │ Local Socket / 127.0.0.1:3306 │
 │                             ▼                               │
 │  ┌───────────────────────────────────────────────────────┐  │
 │  │ MariaDB Service (127.0.0.1 bind-address)              │  │
 │  │ - Isolated DB: nodeapp_db (utf8mb4)                   │  │
 │  │ - Isolated User: nodeapp_user@localhost               │  │
 │  └───────────────────────────────────────────────────────┘  │
 └─────────────────────────────────────────────────────────────┘
```

---

## 2. Phase 0: Initial Server Provisioning

Log in as `root` via SSH:
```bash
ssh root@your_vps_ip
```

### 2.1 Update System & Install Core Packages
```bash
dnf clean all && dnf update -y
dnf install -y epel-release
dnf install -y curl wget git rsync policycoreutils-python-utils firewalld
```

### 2.2 Install Node.js 20 LTS
On AlmaLinux 9, Node.js LTS is maintained through the standard DNF application stream:
```bash
# Enable Node.js 20 stream
dnf module reset nodejs -y
dnf module enable nodejs:20 -y

# Install Node.js and npm
dnf install -y nodejs

# Verify installation
node -v   # Expected: v20.x.x
npm -v    # Expected: 10.x.x
```

### 2.3 Install MariaDB Server
```bash
dnf install -y mariadb-server mariadb
systemctl enable --now mariadb

# Run MariaDB secure installation (or use init_db.sh)
mariadb-secure-installation
```

### 2.4 Install Apache (httpd) and SSL Module
```bash
dnf install -y httpd mod_ssl
systemctl enable --now httpd
```

---

## 3. Phase 1: Security Hardening & Firewalls

### 3.1 SELinux Configuration
AlmaLinux 9 enforces SELinux by default. Apache reverse proxying to localhost port 3000 will be denied unless the network connect boolean is enabled:
```bash
# Allow Apache to connect to network/backend ports
setsebool -P httpd_can_network_connect 1

# Verify boolean status
getsebool httpd_can_network_connect
# Output: httpd_can_network_connect --> on
```

### 3.2 Firewalld Rules
Ensure public traffic can reach HTTP and HTTPS, while keeping application ports internal:
```bash
systemctl enable --now firewalld
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --permanent --add-service=ssh
firewall-cmd --reload

# Verify open services
firewall-cmd --list-services
# Output: http https ssh
```

---

## 4. Phase 2: Database Initialization

1. Clone or copy `almalinux-nodejs-vps-deploykit` into your administrative directory:
```bash
cd /root
git clone https://github.com/jdymitarai/almalinux-nodejs-vps-deploykit.git
cd almalinux-nodejs-vps-deploykit
```

2. Generate a secure database password:
```bash
DB_PASS=$(openssl rand -hex 24)
echo "Generated DB Password: ${DB_PASS}"
```

3. Run the automated database initializer:
```bash
chmod +x init_db.sh
./init_db.sh --db-name nodeapp_db --db-user nodeapp_user --db-pass "${DB_PASS}"
```
This script:
- Creates `/etc/my.cnf.d/99-local-binding.cnf` enforcing `bind-address = 127.0.0.1`.
- Grants least-privilege access to both `'nodeapp_user'@'localhost'` (Unix socket) and `'nodeapp_user'@'127.0.0.1'` (TCP loopback).
- Runs `schema.sql` to establish migrations, users, app settings, and audit tables.
- Validates connection integrity over loopback TCP before completing.

---

## 5. Phase 3: Apache Reverse Proxy & SSL Setup

### 5.1 Obtain Free SSL Certificate via Certbot
```bash
dnf install -y certbot python3-certbot-apache

# Obtain certificate (replace example.com with your actual domain)
certbot certonly --webroot -w /var/www/html -d example.com -d www.example.com
```

### 5.2 Install VirtualHost Configuration
1. Copy `app.conf` to Apache configuration directory:
```bash
cp app.conf /etc/httpd/conf.d/app.conf
```

2. Edit `/etc/httpd/conf.d/app.conf` and replace `example.com` with your real domain:
```bash
sed -i 's/example.com/your-domain.com/g' /etc/httpd/conf.d/app.conf
```

3. Test configuration syntax:
```bash
apachectl configtest
# Output: Syntax OK
```

4. Reload Apache:
```bash
systemctl reload httpd
```

---

## 6. Phase 4: Application Deployment Execution

### 6.1 Prepare Production Secrets
Before running deployment, prepare the persistent shared `.env` file:
```bash
mkdir -p /opt/nodeapp/shared
cp .env.example /opt/nodeapp/shared/.env
chmod 600 /opt/nodeapp/shared/.env

# Update secrets (DB_PASSWORD, APP_SECRET, etc.)
nano /opt/nodeapp/shared/.env
```

### 6.2 Execute Zero-Downtime Deployment
Run `deploy.sh`:
```bash
chmod +x deploy.sh rollback.sh healthcheck.sh
./deploy.sh
```

What `deploy.sh` executes step-by-step:
1. **Pre-flight Checks**: Verifies root UID, AlmaLinux OS, Node.js 20, npm, MariaDB, httpd, SELinux, and firewalld.
2. **System User Setup**: Creates dedicated system user `nodeapp` (`/sbin/nologin`) and `/opt/nodeapp` directory with `chmod 750` isolation.
3. **Atomic Release Directory**: Creates `/opt/nodeapp/releases/<timestamp>`.
4. **Symlink Binding**: Links `/opt/nodeapp/shared/.env` and `/opt/nodeapp/shared/logs` into the release.
5. **Clean Dependency Install**: Runs `npm ci --omit=dev` under user `nodeapp`.
6. **Atomic Pointer Rotation**: Updates `/opt/nodeapp/previous` to previous release, and swaps `/opt/nodeapp/current` to the new release using atomic rename (`mv -Tf`).
7. **Systemd Unit Deployment**: Copies `app.service` to `/etc/systemd/system/app.service`, reloads systemd, and starts the service.
8. **Health Check Gate**: Probes `http://127.0.0.1:3000/health`. If healthy, proceeds. If failed, **triggers automatic rollback** to `/opt/nodeapp/previous`!
9. **Pruning**: Retains only the last 5 releases to prevent disk depletion.

---

## 7. Phase 5: Verification & Automated Rollback

### 7.1 Manual Health Check
```bash
./healthcheck.sh --port 3000 --retries 5
```
Expected output:
```
[HEALTHCHECK] [INFO] Verifying systemd unit status for 'app.service'...
[HEALTHCHECK] [PASS] Systemd service 'app.service' is active (running).
[HEALTHCHECK] [INFO] Probing health endpoint: http://127.0.0.1:3000/health...
[HEALTHCHECK] [PASS] HTTP status 200 OK received from http://127.0.0.1:3000/health
```

### 7.2 Triggering Emergency Rollback
If an application bug is discovered in production, revert immediately to the previous stable release:
```bash
./rollback.sh
```
This instantly swaps the atomic symlink, restarts `app.service`, and confirms recovery via `healthcheck.sh`.

---

## 8. Phase 6: Monitoring, Logs, & System Maintenance

### 8.1 Systemd Service Operations
```bash
# Check service status
systemctl status app.service

# View live application logs
journalctl -u app.service -f

# View last 100 log lines with no pager
journalctl -u app.service -n 100 --no-pager
```

### 8.2 Apache Access & Error Logs
```bash
tail -f /var/log/httpd/app_error.log
tail -f /var/log/httpd/app_access.log
```

### 8.3 SSL Certificate Auto-Renewal
Certbot configures a systemd timer on AlmaLinux 9. Verify it is running:
```bash
systemctl status certbot-renew.timer
certbot renew --dry-run
```

---

## 9. Troubleshooting & FAQ

| Symptom | Cause | Solution |
| :--- | :--- | :--- |
| **Apache 503 Service Unavailable** | SELinux blocking proxy connect | Run `setsebool -P httpd_can_network_connect 1` |
| **Systemd failed to start: 203/EXEC** | Node.js binary path mismatch | Run `which node` and verify `ExecStart` in `/etc/systemd/system/app.service` |
| **Permission Denied accessing /opt/nodeapp** | Incorrect directory ownership | Run `chown -R nodeapp:nodeapp /opt/nodeapp && chmod 750 /opt/nodeapp` |
| **Database Access Denied for 'nodeapp_user'** | Password mismatch in `.env` | Verify `/opt/nodeapp/shared/.env` matches MariaDB credentials |
| **Port 3000 already in use** | Stray process running | Find process: `ss -tulpn \| grep :3000` and kill it, then restart service |

---

## 10. Production Security Audit Checklist

- [x] Dedicated unprivileged system user `nodeapp` with `/sbin/nologin`.
- [x] Filesystem isolation (`chmod 750` on `/opt/nodeapp`, `chmod 600` on `.env`).
- [x] MariaDB strictly bound to loopback `127.0.0.1` (`bind-address`).
- [x] Application database credentials isolated with least privilege.
- [x] Public port 3000 blocked by `firewalld`; only ports 80/443 exposed.
- [x] Systemd security sandbox enabled (`NoNewPrivileges=true`, `ProtectSystem=full`).
- [x] Apache configured with modern TLS 1.2/1.3 ciphers and HSTS headers.
- [x] Atomic symlink releases enabling instant zero-downtime rollback.
- [x] Automated health check gate with self-healing rollback.
