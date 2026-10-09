# Reference Production Node.js Application

A lightweight, zero-external-dependency Node.js reference server tailored for testing and deploying with `almalinux-nodejs-vps-deploykit`.

## Key Features
- **Zero External Dependencies**: Built entirely with native `node:http`, guaranteeing instant deployment without complex compilation steps.
- **Health Check Endpoint**: Exposes `/health` returning HTTP 200 and JSON telemetry (uptime, memory, PID).
- **Graceful Shutdown**: Listens to `SIGTERM` and `SIGINT` signals, closing active server sockets before cleanly terminating.
- **Hardened Defaults**: Disables powered-by headers, sends security response headers (`X-Content-Type-Options: nosniff`, `X-Frame-Options: DENY`).

## Endpoints
- `GET /` - Application metadata, host info, uptime.
- `GET /health` - Health probe for load balancers, systemd, and `healthcheck.sh`.

## Running Locally
```bash
node server.js
```
Override port or host via environment variables:
```bash
PORT=8080 HOST=0.0.0.0 node server.js
```

## Running Tests
```bash
npm test
```
