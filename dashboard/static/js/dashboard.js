/**
 * KIRAT OS Server Dashboard - Real-time WebSocket Client
 * Handles live metrics streaming, chart updates, and UI interactions.
 */

// Configuration: never use an unencrypted WebSocket from an HTTPS page.
const WS_PROTOCOL = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
const WS_PATH = `${WS_PROTOCOL}//${window.location.host}/ws/metrics`;
const RECONNECT_INTERVAL = 3000;
const MAX_RECONNECT_ATTEMPTS = 10;

// Global state
let ws = null;
let reconnectAttempts = 0;
let reconnectTimer = null;
let isConnected = false;
let metricsHistory = [];
const MAX_HISTORY = 60;

// Chart instances
let networkChart = null;
let loadChart = null;
let diskChart = null;

// Initialize dashboard
document.addEventListener('DOMContentLoaded', () => {
    initCharts();
    connectWebSocket();
    updateClock();
    setInterval(updateClock, 1000);
});

// Clock update
function updateClock() {
    const clock = document.getElementById('clock');
    if (clock) {
        clock.textContent = new Date().toLocaleTimeString('en-US', { hour12: false });
    }
}

// Initialize all charts
function initCharts() {
    const chartFont = {
        family: "'Segoe UI', 'Roboto', sans-serif",
        size: 11,
        color: '#94a3b8'
    };

    const gridColor = '#1e293b';

    // Network I/O Line Chart
    const networkCtx = document.getElementById('networkChart');
    if (networkCtx) {
        networkChart = new Chart(networkCtx, {
            type: 'line',
            data: {
                labels: Array(MAX_HISTORY).fill(''),
                datasets: [
                    {
                        label: 'RX (KB/s)',
                        data: Array(MAX_HISTORY).fill(0),
                        borderColor: '#10b981',
                        backgroundColor: 'rgba(16, 185, 129, 0.1)',
                        borderWidth: 2,
                        tension: 0.4,
                        fill: true,
                        pointRadius: 0,
                        pointHoverRadius: 4
                    },
                    {
                        label: 'TX (KB/s)',
                        data: Array(MAX_HISTORY).fill(0),
                        borderColor: '#8b5cf6',
                        backgroundColor: 'rgba(139, 92, 246, 0.1)',
                        borderWidth: 2,
                        tension: 0.4,
                        fill: true,
                        pointRadius: 0,
                        pointHoverRadius: 4
                    }
                ]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                animation: { duration: 0 },
                interaction: { mode: 'index', intersect: false },
                plugins: {
                    legend: {
                        labels: { color: '#94a3b8', font: chartFont, boxWidth: 12 }
                    },
                    tooltip: {
                        backgroundColor: '#1a1f2e',
                        titleColor: '#e2e8f0',
                        bodyColor: '#94a3b8',
                        borderColor: '#1e293b',
                        borderWidth: 1
                    }
                },
                scales: {
                    x: {
                        display: false
                    },
                    y: {
                        grid: { color: gridColor },
                        ticks: { color: '#64748b', font: chartFont },
                        beginAtZero: true
                    }
                }
            }
        });
    }

    // Load Average Chart
    const loadCtx = document.getElementById('loadChart');
    if (loadCtx) {
        loadChart = new Chart(loadCtx, {
            type: 'line',
            data: {
                labels: Array(MAX_HISTORY).fill(''),
                datasets: [
                    {
                        label: '1 min',
                        data: Array(MAX_HISTORY).fill(0),
                        borderColor: '#06b6d4',
                        backgroundColor: 'rgba(6, 182, 212, 0.1)',
                        borderWidth: 2,
                        tension: 0.4,
                        fill: true,
                        pointRadius: 0
                    },
                    {
                        label: '5 min',
                        data: Array(MAX_HISTORY).fill(0),
                        borderColor: '#f59e0b',
                        backgroundColor: 'rgba(245, 158, 11, 0.1)',
                        borderWidth: 2,
                        tension: 0.4,
                        fill: true,
                        pointRadius: 0
                    },
                    {
                        label: '15 min',
                        data: Array(MAX_HISTORY).fill(0),
                        borderColor: '#ec4899',
                        backgroundColor: 'rgba(236, 72, 153, 0.1)',
                        borderWidth: 2,
                        tension: 0.4,
                        fill: true,
                        pointRadius: 0
                    }
                ]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                animation: { duration: 0 },
                interaction: { mode: 'index', intersect: false },
                plugins: {
                    legend: {
                        labels: { color: '#94a3b8', font: chartFont, boxWidth: 12 }
                    },
                    tooltip: {
                        backgroundColor: '#1a1f2e',
                        titleColor: '#e2e8f0',
                        bodyColor: '#94a3b8',
                        borderColor: '#1e293b',
                        borderWidth: 1
                    }
                },
                scales: {
                    x: { display: false },
                    y: {
                        grid: { color: gridColor },
                        ticks: { color: '#64748b', font: chartFont },
                        beginAtZero: true
                    }
                }
            }
        });
    }

    // Disk Usage Pie Chart
    const diskCtx = document.getElementById('diskChart');
    if (diskCtx) {
        diskChart = new Chart(diskCtx, {
            type: 'doughnut',
            data: {
                labels: ['Used', 'Free'],
                datasets: [{
                    data: [0, 100],
                    backgroundColor: ['#06b6d4', '#1e293b'],
                    borderColor: '#0a0e17',
                    borderWidth: 2,
                    hoverOffset: 4
                }]
            },
            options: {
                responsive: true,
                maintainAspectRatio: false,
                cutout: '65%',
                plugins: {
                    legend: {
                        position: 'bottom',
                        labels: { color: '#94a3b8', font: chartFont, padding: 16, boxWidth: 12 }
                    },
                    tooltip: {
                        backgroundColor: '#1a1f2e',
                        titleColor: '#e2e8f0',
                        bodyColor: '#94a3b8',
                        borderColor: '#1e293b',
                        borderWidth: 1,
                        callbacks: {
                            label: function(context) {
                                const val = context.raw;
                                const total = context.dataset.data.reduce((a, b) => a + b, 0);
                                const pct = ((val / total) * 100).toFixed(1);
                                return `${context.label}: ${formatBytes(val)} (${pct}%)`;
                            }
                        }
                    }
                }
            }
        });
    }
}

// Browser authentication uses only an HttpOnly same-origin session cookie.
let authenticationInProgress = false;

async function clearSession() {
    try {
        await fetch('/api/logout', { method: 'POST', credentials: 'same-origin' });
    } catch (error) {
        console.warn('Session cleanup failed:', error);
    }
}

async function promptForSession() {
    while (true) {
        const apiKey = prompt('Enter the dashboard API key:');
        if (!apiKey) {
            updateConnectionStatus('authentication required');
            return false;
        }

        try {
            const response = await fetch('/api/session', {
                method: 'POST',
                headers: { 'Authorization': `Bearer ${apiKey}` },
                credentials: 'same-origin',
                cache: 'no-store'
            });
            if (response.ok) return true;
            if (response.status === 401 || response.status === 403) {
                await clearSession();
                alert('Authentication failed. Please enter the API key again.');
                continue;
            }
            const data = await response.json().catch(() => ({}));
            alert(`Session creation failed: ${data.error || response.status}`);
            updateConnectionStatus('authentication failed');
            return false;
        } catch (error) {
            console.error('Session creation failed:', error);
            alert('Session creation failed. Check the dashboard connection.');
            updateConnectionStatus('authentication failed');
            return false;
        }
    }
}

async function ensureSession() {
    try {
        const response = await fetch('/api/session', {
            credentials: 'same-origin',
            cache: 'no-store'
        });
        if (response.ok) return true;
        if (response.status !== 401 && response.status !== 403) {
            updateConnectionStatus('authentication unavailable');
            return false;
        }
    } catch (error) {
        console.error('Session validation failed:', error);
        updateConnectionStatus('authentication unavailable');
        return false;
    }

    await clearSession();
    return promptForSession();
}

async function connectWebSocket() {
    if (authenticationInProgress ||
        (ws && (ws.readyState === WebSocket.OPEN || ws.readyState === WebSocket.CONNECTING))) {
        return;
    }

    authenticationInProgress = true;
    let authenticated = false;
    try {
        authenticated = await ensureSession();
    } finally {
        authenticationInProgress = false;
    }
    if (!authenticated) return;

    try {
        ws = new WebSocket(WS_PATH);

        ws.onopen = () => {
            console.log('WebSocket connected');
            isConnected = true;
            reconnectAttempts = 0;
            updateConnectionStatus('connected');
            ws.send(JSON.stringify({ type: 'subscribe' }));
        };

        ws.onmessage = (event) => {
            try {
                handleMessage(JSON.parse(event.data));
            } catch (error) {
                console.error('Failed to parse message:', error);
            }
        };

        ws.onerror = (error) => {
            console.error('WebSocket error:', error);
            isConnected = false;
            updateConnectionStatus('disconnected');
        };

        ws.onclose = (event) => {
            console.log('WebSocket closed');
            isConnected = false;
            updateConnectionStatus('disconnected');
            if (event.code === 1008) {
                updateConnectionStatus('authentication expired');
                clearSession().finally(connectWebSocket);
                return;
            }
            scheduleReconnect();
        };
    } catch (error) {
        console.error('Failed to create WebSocket:', error);
        scheduleReconnect();
    }
}

// Schedule reconnection
function scheduleReconnect() {
    if (reconnectTimer) return;

    if (reconnectAttempts >= MAX_RECONNECT_ATTEMPTS) {
        console.error('Max reconnection attempts reached');
        return;
    }

    reconnectAttempts++;
    console.log(`Reconnecting in ${RECONNECT_INTERVAL}ms (attempt ${reconnectAttempts})`);

    reconnectTimer = setTimeout(() => {
        reconnectTimer = null;
        connectWebSocket();
    }, RECONNECT_INTERVAL);
}

// Update connection status UI
function updateConnectionStatus(status) {
    const indicator = document.getElementById('wsStatus');
    if (indicator) {
        indicator.className = `ws-status ${status}`;
        indicator.textContent = status === 'connected' ? 'LIVE' : 'OFFLINE';
    }
    
    const dot = document.getElementById('statusDot');
    if (dot) {
        dot.className = `status-dot ${status === 'connected' ? '' : 'critical'}`;
    }
}

// Handle incoming WebSocket messages
function handleMessage(message) {
    if (message.type === 'metrics') {
        updateDashboard(message.data);
    } else if (message.type === 'pong') {
        // Keepalive response
    } else if (message.type === 'ack') {
        console.log('Server:', message.message);
    }
}

// Update dashboard with new metrics
function updateDashboard(data) {
    // Store history
    metricsHistory.push(data);
    if (metricsHistory.length > MAX_HISTORY) {
        metricsHistory.shift();
    }

    // Update CPU
    updateCPU(data.cpu);
    
    // Update Memory
    updateMemory(data.memory);
    
    // Update Network
    updateNetwork(data.network);
    
    // Update Thermal
    updateThermal(data.thermal);
    
    // Update Load
    updateLoad(data.load);
    
    // Update Processes
    updateProcesses(data.processes);
    
    // Update AI Status
    updateAIStatus(data.ai_status);
    
    // Update Threats
    updateThreats(data.threats);
    
    // Update Honeypot
    updateHoneypot(data.honeypot);
    
    // Update Disk
    updateDisk(data.disk);
}

// Update CPU display
function updateCPU(cpu) {
    const gaugeFill = document.getElementById('cpuGaugeFill');
    const gaugeValue = document.getElementById('cpuGaugeValue');
    const freqValue = document.getElementById('cpuFreq');
    const coreCount = document.getElementById('coreCount');
    
    if (gaugeFill && gaugeValue) {
        const percent = cpu.percent_average || 0;
        const circumference = 2 * Math.PI * 70; // r=70
        const offset = circumference - (percent / 100) * circumference;
        
        gaugeFill.style.strokeDasharray = circumference;
        gaugeFill.style.strokeDashoffset = offset;
        
        // Color based on usage
        if (percent > 80) {
            gaugeFill.style.stroke = '#ef4444';
        } else if (percent > 50) {
            gaugeFill.style.stroke = '#f59e0b';
        } else {
            gaugeFill.style.stroke = '#06b6d4';
        }
        
        gaugeValue.textContent = `${percent.toFixed(1)}%`;
    }
    
    if (freqValue) {
        freqValue.textContent = `${(cpu.freq_current / 1000).toFixed(2)} GHz`;
    }
    
    if (coreCount) {
        coreCount.textContent = `${cpu.count} cores`;
    }
    
    // Update core bars
    if (cpu.percent_per_core) {
        cpu.percent_per_core.forEach((p, i) => {
            const bar = document.getElementById(`core-bar-${i}`);
            if (bar) {
                bar.style.height = `${p}%`;
            }
        });
    }
}

// Update Memory display
function updateMemory(mem) {
    const fill = document.getElementById('memoryBarFill');
    const text = document.getElementById('memoryBarText');
    const used = document.getElementById('memUsed');
    const total = document.getElementById('memTotal');
    const swap = document.getElementById('memSwap');
    
    if (fill) {
        fill.style.width = `${mem.percent}%`;
        fill.className = 'memory-bar-fill' + (mem.percent > 80 ? ' warning' : '');
    }
    
    if (text) {
        text.textContent = `${mem.percent.toFixed(1)}%`;
    }
    
    if (used) used.textContent = formatBytes(mem.used);
    if (total) total.textContent = formatBytes(mem.total);
    if (swap) swap.textContent = `${mem.swap_percent.toFixed(1)}%`;
}

// Update Network chart
function updateNetwork(net) {
    if (!networkChart) return;
    
    const rxKB = (net.rx_bytes_sec / 1024).toFixed(2);
    const txKB = (net.tx_bytes_sec / 1024).toFixed(2);
    
    // Update chart data
    networkChart.data.datasets[0].data.shift();
    networkChart.data.datasets[0].data.push(parseFloat(rxKB));
    networkChart.data.datasets[1].data.shift();
    networkChart.data.datasets[1].data.push(parseFloat(txKB));
    networkChart.update('none');
    
    // Update stats
    const rxEl = document.getElementById('netRx');
    const txEl = document.getElementById('netTx');
    if (rxEl) rxEl.textContent = `${rxKB} KB/s`;
    if (txEl) txEl.textContent = `${txKB} KB/s`;
}

// Update Thermal display
function updateThermal(thermal) {
    const icon = document.getElementById('thermalIcon');
    const value = document.getElementById('thermalValue');
    const status = document.getElementById('thermalStatus');
    
    const temp = thermal.cpu_temp;
    const available = typeof temp === 'number';

    if (icon) icon.textContent = '🌡️';

    if (value) {
        value.textContent = available ? temp.toFixed(1) : '--';
        value.style.color = !available ? '#94a3b8' : temp > 80 ? '#ef4444' : temp > 60 ? '#f59e0b' : '#10b981';
    }

    if (status) {
        status.textContent = thermal.status || 'unavailable';
        status.className = `thermal-status ${thermal.status || 'unavailable'}`;
    }
}

// Update Load Average
function updateLoad(load) {
    const l1 = document.getElementById('load1');
    const l5 = document.getElementById('load5');
    const l15 = document.getElementById('load15');
    
    const cpuCount = navigator.hardwareConcurrency || 4;
    
    function getLoadClass(val) {
        const ratio = val / cpuCount;
        if (ratio > 0.9) return 'critical';
        if (ratio > 0.7) return 'warning';
        return '';
    }
    
    if (l1) {
        l1.textContent = load.load1.toFixed(2);
        l1.className = `load-value ${getLoadClass(load.load1)}`;
    }
    if (l5) {
        l5.textContent = load.load5.toFixed(2);
        l5.className = `load-value ${getLoadClass(load.load5)}`;
    }
    if (l15) {
        l15.textContent = load.load15.toFixed(2);
        l15.className = `load-value ${getLoadClass(load.load15)}`;
    }
    
    // Update load chart
    if (loadChart) {
        loadChart.data.datasets[0].data.shift();
        loadChart.data.datasets[0].data.push(load.load1);
        loadChart.data.datasets[1].data.shift();
        loadChart.data.datasets[1].data.push(load.load5);
        loadChart.data.datasets[2].data.shift();
        loadChart.data.datasets[2].data.push(load.load15);
        loadChart.update('none');
    }
}

// Update Processes
function updateProcesses(procs) {
    const total = document.getElementById('procTotal');
    const threads = document.getElementById('procThreads');
    const zombies = document.getElementById('procZombies');
    const running = document.getElementById('procRunning');
    
    if (total) total.textContent = procs.total.toLocaleString();
    if (threads) threads.textContent = procs.threads.toLocaleString();
    if (zombies) {
        zombies.textContent = procs.zombies.toString();
        zombies.className = `process-stat-value ${procs.zombies > 0 ? 'warning' : ''}`;
    }
    if (running) running.textContent = procs.running.toString();
}

// Update AI Status
function updateAIStatus(ai) {
    const indicator = document.getElementById('aiStatusIndicator');
    const text = document.getElementById('aiStatusText');
    const model = document.getElementById('aiModel');
    const requests = document.getElementById('aiRequests');
    const gpu = document.getElementById('aiGpu');
    const batch = document.getElementById('aiBatch');
    
    if (indicator) {
        indicator.className = `ai-status-indicator ${ai.status}`;
    }
    
    if (text) {
        text.textContent = ai.status;
        text.className = `ai-status-text ${ai.status}`;
    }
    
    if (model) model.textContent = ai.model_loaded || 'N/A';
    if (requests) requests.textContent = typeof ai.inference_requests_sec === 'number' ? ai.inference_requests_sec.toFixed(1) : '--';
    if (gpu) gpu.textContent = typeof ai.gpu_utilization === 'number' ? `${ai.gpu_utilization.toFixed(0)}%` : '--';
    if (batch) batch.textContent = ai.batch_size ?? '--';
}

// Update Threats
function updateThreats(threats) {
    const container = document.getElementById('threatList');
    if (!container) return;
    
    container.innerHTML = '';

    if (!threats.length) {
        container.textContent = 'Threat telemetry unavailable — no integration configured.';
    }

    threats.forEach(threat => {
        const item = document.createElement('div');
        item.className = `threat-item ${threat.severity}`;
        
        const time = new Date(threat.timestamp).toLocaleTimeString('en-US', { hour12: false });
        
        item.innerHTML = `
            <div class="threat-header">
                <span class="threat-id">${threat.id}</span>
                <span class="threat-severity ${threat.severity}">${threat.severity}</span>
            </div>
            <div class="threat-description">${threat.description}</div>
            <div class="threat-meta">
                <span>📍 ${threat.source}</span>
                <span>🕐 ${time}</span>
                <span>📡 ${threat.ip}</span>
            </div>
        `;
        
        container.appendChild(item);
    });
    
    // An empty unavailable feed must not be displayed as a green "all clear".
    const badge = document.getElementById('threatCount');
    if (badge) {
        if (!threats.length) {
            badge.textContent = '—';
            badge.style.color = '#94a3b8';
        } else {
            const activeCount = threats.filter(t => t.status === 'active').length;
            badge.textContent = activeCount;
            badge.style.color = activeCount > 0 ? '#ef4444' : '#10b981';
        }
    }
}

// Update Honeypot
function updateHoneypot(honeypot) {
    const container = document.getElementById('honeypotLog');
    const total = document.getElementById('honeypotTotal');
    const blocked = document.getElementById('honeypotBlocked');
    const sessions = document.getElementById('honeypotSessions');

    if (total) total.textContent = honeypot.total_triggers ?? '--';
    if (blocked) blocked.textContent = honeypot.blocked_ips ?? '--';
    if (sessions) sessions.textContent = honeypot.active_sessions ?? '--';

    if (!container || !honeypot.honeypots) return;

    container.innerHTML = '';
    if (!honeypot.honeypots.length) {
        container.textContent = honeypot.detail || 'Honeypot telemetry unavailable.';
    }
    
    honeypot.honeypots.forEach(hp => {
        const item = document.createElement('div');
        item.className = 'honeypot-item';
        
        const iconMap = { 'ssh-honeypot': '🔐', 'http-honeypot': '🌐', 'ftp-honeypot': '📁' };
        const typeMap = { 'ssh-honeypot': 'ssh', 'http-honeypot': 'http', 'ftp-honeypot': 'ftp' };
        
        item.innerHTML = `
            <div class="honeypot-icon ${typeMap[hp.name] || 'ssh'}">${iconMap[hp.name] || '🛡️'}</div>
            <div class="honeypot-info">
                <div class="honeypot-name">${hp.name}</div>
                <div class="honeypot-detail">Port ${hp.port} • ${hp.status}</div>
            </div>
            <div class="honeypot-count">${hp.triggers}</div>
        `;
        
        container.appendChild(item);
    });
}

// Update Disk
function updateDisk(disk) {
    if (!diskChart) return;
    
    diskChart.data.datasets[0].data = [disk.used, disk.free];
    diskChart.update();
    
    // Update disk I/O stats
    const readEl = document.getElementById('diskRead');
    const writeEl = document.getElementById('diskWrite');
    const percentEl = document.getElementById('diskPercent');
    
    if (readEl) readEl.textContent = `${formatBytes(disk.read_bytes_sec)}/s`;
    if (writeEl) writeEl.textContent = `${formatBytes(disk.write_bytes_sec)}/s`;
    if (percentEl) percentEl.textContent = `${disk.percent}%`;
}

// Utility: Format bytes
function formatBytes(bytes, decimals = 2) {
    if (bytes === 0) return '0 B';
    
    const k = 1024;
    const dm = decimals < 0 ? 0 : decimals;
    const sizes = ['B', 'KB', 'MB', 'GB', 'TB', 'PB'];
    
    const i = Math.floor(Math.log(bytes) / Math.log(k));
    
    return parseFloat((bytes / Math.pow(k, i)).toFixed(dm)) + ' ' + sizes[i];
}

// Commands currently return 501 until a real authenticated integration exists.
async function sendCommand(command, target = 'sentinel', params = {}) {
    try {
        const response = await fetch('/api/command', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            credentials: 'same-origin',
            body: JSON.stringify({ command, target, params })
        });
        const data = await response.json();

        if (response.status === 401 || response.status === 403) {
            await clearSession();
            updateConnectionStatus('authentication expired');
            connectWebSocket();
            return;
        }
        if (response.ok) {
            console.log('Command result:', data);
            alert(data.message || 'Command completed');
        } else {
            console.error('Command failed:', data);
            alert(`Error: ${data.error}`);
        }
    } catch (error) {
        console.error('Failed to send command:', error);
        alert('Failed to send command');
    }
}

async function logout() {
    if (ws) ws.close();
    await clearSession();
    updateConnectionStatus('logged out');
}

// Export for debugging and explicit logout.
window.dashboard = {
    ws,
    metricsHistory,
    sendCommand,
    logout,
    formatBytes
};
