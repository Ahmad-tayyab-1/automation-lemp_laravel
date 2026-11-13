#!/usr/bin/env bash
# install.sh - Installs local dependencies for the deployer (bash edition: no Ansible).
# Safe to run multiple times by a normal user (uses sudo where needed).
set -Eeuo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ ! -f /etc/os-release ]]; then
  echo "Unsupported system: /etc/os-release not found. Only Ubuntu and Debian are supported." >&2
  exit 1
fi

# shellcheck source=/dev/null
. /etc/os-release
case "${ID:-}" in
  ubuntu|debian) ;;
  *)
    echo "Unsupported system: ${ID:-unknown}. Only Ubuntu and Debian are supported at this time." >&2
    exit 1
    ;;
esac

SUDO=""
if [[ $EUID -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
  else
    echo "This script requires root privileges or sudo to install packages." >&2
    exit 1
  fi
fi

echo "Installing required packages..."
$SUDO apt-get update -y
$SUDO apt-get install -y jq git openssl openssh-client util-linux whiptail python3 tar

chmod +x "$SRC/deploy.sh" "$SRC/install.sh"
mkdir -p "$SRC/data/logs" "$SRC/data/.locks"
chmod 700 "$SRC/data" "$SRC/data/.locks" 2>/dev/null || true

if [[ ! -f "$SRC/sites.json" ]]; then
  echo '{"sites":{}}' > "$SRC/sites.json"
fi
if [[ ! -f "$SRC/targets.json" ]]; then
  echo '{"targets":{}}' > "$SRC/targets.json"
fi

echo "Installation complete. Run ./deploy.sh to deploy."
