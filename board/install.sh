#!/usr/bin/env bash
# radxa-commander board install. Run ONCE on the A7A as root (or via sudo).
# Idempotent: safe to re-run. Prints the API token at the end (enter it in the App).
set -euo pipefail
cd "$(dirname "$0")"

install -m 0755 commander-api.py /usr/local/bin/commander-api.py
install -m 0644 -o root -g root commander-api.service /etc/systemd/system/commander-api.service
mkdir -p /etc/radxa-commander
chmod 700 /etc/radxa-commander
if [[ ! -s /etc/radxa-commander/token ]]; then
  python3 -c "import secrets; print(secrets.token_hex(16))" > /etc/radxa-commander/token
  chmod 600 /etc/radxa-commander/token
fi
command -v iw >/dev/null 2>&1 || apt-get install -y iw || true
systemctl daemon-reload
systemctl enable --now commander-api.service
sleep 1
systemctl is-active commander-api.service
echo "--- commander token (save into the App) ---"
cat /etc/radxa-commander/token
echo "--- api ---"
curl -s -m 5 http://127.0.0.1:18080/api/hello; echo
