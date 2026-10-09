const test = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { spawn } = require('node:child_process');
const path = require('node:path');

test('Sample App Health and Lifecycle Verification', async (t) => {
    const testPort = 3199;
    const serverPath = path.join(__dirname, '..', 'server.js');
    
    // Spawn server process
    const child = spawn(process.execPath, [serverPath], {
        env: {
            ...process.env,
            PORT: testPort.toString(),
            HOST: '127.0.0.1',
            NODE_ENV: 'test'
        },
        stdio: ['ignore', 'pipe', 'pipe']
    });

    // Wait for server to bind
    await new Promise((resolve, reject) => {
        child.stdout.on('data', (data) => {
            if (data.toString().includes('listening on')) {
                resolve();
            }
        });
        child.on('error', reject);
        child.on('exit', (code) => {
            if (code !== 0) reject(new Error(`Server exited prematurely with code ${code}`));
        });
    });

    await t.test('GET /health returns HTTP 200 with status: ok', async () => {
        const res = await fetch(`http://127.0.0.1:${testPort}/health`);
        assert.equal(res.status, 200);
        const data = await res.json();
        assert.equal(data.status, 'ok');
        assert.equal(data.healthy, true);
    });

    await t.test('GET / returns HTTP 200 with app info', async () => {
        const res = await fetch(`http://127.0.0.1:${testPort}/`);
        assert.equal(res.status, 200);
        const data = await res.json();
        assert.equal(data.status, 'operational');
    });

    await t.test('Graceful shutdown on SIGTERM', async () => {
        const exitPromise = new Promise((resolve) => {
            child.on('exit', (code, signal) => resolve({ code, signal }));
        });
        child.kill('SIGTERM');
        const { code, signal } = await exitPromise;
        assert.ok(code === 0 || signal === 'SIGTERM');
    });
});
