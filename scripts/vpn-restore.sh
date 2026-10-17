#!/usr/bin/env bash
# vpn-restore.sh — восстановление конфигов из бэкапа
#
# Использование:
#   bash vpn-restore.sh /path/to/vpn-stack_YYYYMMDD_HHMMSS.tar.gz
#
# Кладёт конфиги в /etc/wireguard/ и применяет awg-quick up.

set -euo pipefail

ARCHIVE="${1:-}"
if [[ -z "$ARCHIVE" || ! -f "$ARCHIVE" ]]; then
  echo "Использование: $0 <archive.tar.gz>"
  echo
  echo "Доступные бэкапы:"
  for h in tr-vps miami; do
    ssh -o ConnectTimeout=5 "$h" "ls -1 /var/backups/vpn/ 2>/dev/null" 2>/dev/null | \
      sed "s/^/  $h: /"
  done
  exit 1
fi

TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT
tar -xzf "$ARCHIVE" -C "$TMPDIR"

# tr-vps
if [[ -d "$TMPDIR/tr-vps" ]]; then
  echo "→ tr-vps"
  for f in awg0 awg1; do
    if [[ -f "$TMPDIR/tr-vps/${f}.conf" ]]; then
      scp "$TMPDIR/tr-vps/${f}.conf" tr-vps:/tmp/${f}.conf.new
      ssh tr-vps "export SUDO_ASKPASS=/tmp/_askpass.sh; \
        sudo -A cp -a /etc/wireguard/${f}.conf /etc/wireguard/${f}.conf.bak-pre-restore && \
        sudo -A cp -a /tmp/${f}.conf.new /etc/wireguard/${f}.conf && \
        sudo -A /usr/local/bin/awg-quick down ${f} 2>/dev/null || true; \
        sudo -A /usr/local/bin/awg-quick up ${f}"
      echo "  ✓ ${f}.conf восстановлен"
    fi
  done
fi

# Miami
if [[ -d "$TMPDIR/miami" ]]; then
  echo "→ miami"
  for f in awg1-trvps; do
    if [[ -f "$TMPDIR/miami/${f}.conf" ]]; then
      scp "$TMPDIR/miami/${f}.conf" miami:/tmp/${f}.conf.new
      ssh miami "export SUDO_ASKPASS=/tmp/_askpass.sh; \
        sudo -A cp -a /etc/wireguard/${f}.conf /etc/wireguard/${f}.conf.bak-pre-restore && \
        sudo -A cp -a /tmp/${f}.conf.new /etc/wireguard/${f}.conf && \
        sudo -A /usr/local/bin/awg-quick down awg1 2>/dev/null || true; \
        sudo -A /usr/local/bin/awg-quick up awg1"
      echo "  ✓ ${f}.conf восстановлен"
    fi
  done
fi

echo
echo "Готово. Проверить: bash scripts/vpn-health.sh"
