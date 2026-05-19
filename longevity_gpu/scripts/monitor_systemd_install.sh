#!/usr/bin/env bash
# Copyright (c) 2026 Nenad Mićić <nenad@micic.be>
# SPDX-License-Identifier: Apache-2.0
# monitor_systemd_install.sh — generate + install systemd timer for the
# automated kt-monitor daemon. Run on whatever persistent host you want
# to do the monitoring from (operator's laptop, central server, small VPS).
#
# Idempotent. Re-running just refreshes the unit files and restarts the
# timer.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run as root (systemd unit install needs it)"; exit 1; }

SSH_HOST="${SSH_HOST:?set SSH_HOST=root@<gpu-vm-ip>}"
SSH_PORT="${SSH_PORT:?set SSH_PORT=<gpu-vm-ssh-port>}"
N_GPUS="${N_GPUS:-4}"
ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL:?set ALERT_WEBHOOK_URL=https://ntfy.sh/<your-topic>}"
INTERVAL_MIN="${INTERVAL_MIN:-30}"          # cron cadence in minutes
KT_REPO_ROOT="${KT_REPO_ROOT:?set KT_REPO_ROOT=/path/to/k-tuplet-search}"
RUN_USER="${RUN_USER:-$SUDO_USER}"
[[ -z "$RUN_USER" || "$RUN_USER" == "root" ]] && RUN_USER="root"

[[ -x "$KT_REPO_ROOT/longevity_gpu/scripts/monitor_daemon.sh" ]] \
    || { echo "FATAL: $KT_REPO_ROOT/longevity_gpu/scripts/monitor_daemon.sh not found/executable"; exit 2; }

cat > /etc/systemd/system/kt-monitor.service <<EOF
[Unit]
Description=kt-monitor daemon — one-shot check of the GPU campaign + anomaly alerting
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
User=$RUN_USER
Environment="SSH_HOST=$SSH_HOST"
Environment="SSH_PORT=$SSH_PORT"
Environment="N_GPUS=$N_GPUS"
Environment="ALERT_WEBHOOK_URL=$ALERT_WEBHOOK_URL"
Environment="REPO_ROOT=$KT_REPO_ROOT"
ExecStart=/bin/bash $KT_REPO_ROOT/longevity_gpu/scripts/monitor_daemon.sh
StandardOutput=append:/var/log/kt-monitor.log
StandardError=append:/var/log/kt-monitor.log
EOF

cat > /etc/systemd/system/kt-monitor.timer <<EOF
[Unit]
Description=kt-monitor timer — fires the daemon every $INTERVAL_MIN min
Requires=kt-monitor.service

[Timer]
OnBootSec=1min
OnUnitActiveSec=${INTERVAL_MIN}min
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now kt-monitor.timer

echo
echo "[+] kt-monitor.timer installed and started"
echo "    Cadence: every $INTERVAL_MIN min"
echo "    User: $RUN_USER"
echo "    SSH target: $SSH_HOST:$SSH_PORT (N_GPUS=$N_GPUS)"
echo "    Alert webhook: $ALERT_WEBHOOK_URL"
echo "    Service log: /var/log/kt-monitor.log"
echo "    Daily structured log: \$HOME/.kt_monitor/log/daily-YYYY-MM-DD.log"
echo
echo "Inspect:"
echo "  systemctl status kt-monitor.timer"
echo "  systemctl list-timers kt-monitor.timer"
echo "  journalctl -u kt-monitor.service -n 50"
echo "  tail -f /var/log/kt-monitor.log"
echo
echo "Stop:"
echo "  systemctl disable --now kt-monitor.timer"
echo
echo "Test a single tick now:"
echo "  systemctl start kt-monitor.service"
