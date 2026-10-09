#!/usr/bin/env node
/**
 * Production-ready Reference Node.js Server
 * Designed for AlmaLinux 9 / RHEL 9 Systemd Environment
 */

const http = require('node:http');
const os = require('node:os');

const PORT = parseInt(process.env.PORT || '3000', 10);
const HOST = process.env.HOST || '127.0.0.1';
const NODE_ENV = process.env.NODE_ENV || 'production';
const APP_NAME = process.env.APP_NAME || 'DeployKit Reference App';
const START_TIME = Date.now();

const server = http.createServer((req, res) => {
    const url = new URL(req.url, `http://${req.headers.host || 'localhost'}`);
    const pathname = url.pathname;

    // Set standard security headers
    res.setHeader('X-Content-Type-Options', 'nosniff');
    res.setHeader('X-Frame-Options', 'DENY');
    res.setHeader('X-Process-Id', process.pid.toString());

    if (req.method === 'GET' && (pathname === '/health' || pathname === '/healthz')) {
        const payload = {
            status: 'ok',
            healthy: true,
            uptime_seconds: Math.floor((Date.now() - START_TIME) / 1000),
            timestamp: new Date().toISOString(),
            pid: process.pid,
            memory: process.memoryUsage(),
            environment: NODE_ENV
        };
        res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
        return res.end(JSON.stringify(payload, null, 2));
    }

    if (req.method === 'GET' && pathname === '/') {
        const payload = {
            name: APP_NAME,
            version: '1.0.0',
            status: 'operational',
            system: {
                platform: process.platform,
                node_version: process.version,
                hostname: os.hostname(),
                arch: os.arch(),
                loadavg: os.loadavg()
            },
            time: new Date().toISOString()
        };
        res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
        return res.end(JSON.stringify(payload, null, 2));
    }

    // 404 Fallback
    res.writeHead(404, { 'Content-Type': 'application/json; charset=utf-8' });
    return res.end(JSON.stringify({ error: 'Not Found', path: pathname }));
});

// Start Server
server.listen(PORT, HOST, () => {
    console.log(`[${new Date().toISOString()}] [INFO] ${APP_NAME} listening on http://${HOST}:${PORT} (PID: ${process.pid}, ENV: ${NODE_ENV})`);
});

// Graceful Shutdown Handler
function handleGracefulShutdown(signal) {
    console.log(`[${new Date().toISOString()}] [INFO] Received ${signal}. Commencing graceful shutdown...`);
    
    server.close((err) => {
        if (err) {
            console.error(`[${new Date().toISOString()}] [ERROR] Error during server termination:`, err);
            process.exit(1);
        }
        console.log(`[${new Date().toISOString()}] [INFO] HTTP server successfully closed. Process exiting cleanly.`);
        process.exit(0);
    });

    // Force terminate if active sockets fail to drain within 10 seconds
    setTimeout(() => {
        console.error(`[${new Date().toISOString()}] [WARN] Forcefully terminating active sockets after timeout.`);
        process.exit(1);
    }, 10000).unref();
}

process.on('SIGTERM', () => handleGracefulShutdown('SIGTERM'));
process.on('SIGINT', () => handleGracefulShutdown('SIGINT'));
process.on('SIGHUP', () => {
    console.log(`[${new Date().toISOString()}] [INFO] Received SIGHUP from systemd reload. Refreshing configurations...`);
});
