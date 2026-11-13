# managed by deployer: restart {{ restart_label }} when it crashes (a clean "systemctl stop" stays stopped)
[Service]
Restart=on-failure
RestartSec=5s
