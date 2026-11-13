#!/bin/sh
# managed by deployer (deploy.sh firewall): csf runs this after it has loaded its rules.
# csf flushes every iptables table when it (re)starts, which removes Docker's NAT and forwarding
# rules: published container ports and the containers' internet access stop working. Docker
# creates its rules again when its daemon restarts; with "live-restore" (/etc/docker/daemon.json)
# the containers keep running meanwhile.
# Several csf reloads in a row hit systemd's start limit and Docker stayed down ("start-limit-hit"):
# the counter is reset first, and a Docker that failed that way is started again too.
if command -v systemctl >/dev/null 2>&1 && { systemctl is-active --quiet docker || systemctl is-failed --quiet docker; }; then
    systemctl reset-failed docker.service docker.socket >/dev/null 2>&1
    systemctl restart docker
fi
exit 0
