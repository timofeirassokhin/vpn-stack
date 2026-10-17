#!/usr/bin/env bash
# vpn-backup.sh — бэкап конфигов VPN-стека
#
# Использование: bash vpn-backup.sh
# Кладёт тарбол с датой в /var/backups/vpn/ на каждом хосте.
# Не требует секретов: [Interface]/[Peer] PrivateKey/PSK остаются в tar,
# но архив НЕ шифруется — это задача отдельного шифрования диска / offsite.

set -euo pipefail

REMOTE_HOSTS=("tr-vps" "miami")
BACKUP_ROOT="/var/backups/vpn"
STAMP=$(date +%Y%m%d_%H%M%S)
ARCHIVE="/tmp/vpn-stack_${STAMP}.tar.gz"

# Собираем локально
TMPDIR=$(mktemp -d)
trap "rm -rf $TMPDIR" EXIT

for h in "${REMOTE_HOSTS[@]}"; do
  mkdir -p "$TMPDIR/$h"
  echo "→ $h"
  for f in awg0 awg1; do
    ssh -o ConnectTimeout=5 "$h" \
      "export SUDO_ASKPASS=/tmp/_askpass.sh; sudo -A test -f /etc/wireguard/${f}.conf && \
       sudo -A cat /etc/wireguard/${f}.conf" 2>/dev/null \
      > "$TMPDIR/$h/${f}.conf" || echo "  - ${f}.conf отсутствует"
  done
  # Miami: awg1-trvps.conf
  ssh -o ConnectTimeout=5 "$h" \
    "export SUDO_ASKPASS=/tmp/_askpass.sh; sudo -A test -f /etc/wireguard/awg1-trvps.conf && \
     sudo -A cat /etc/wireguard/awg1-trvps.conf" 2>/dev/null \
    > "$TMPDIR/$h/awg1-trvps.conf" 2>/dev/null || true

  # routes.batch (большой файл — НЕ обязательно, читаем только размер)
  ssh -o ConnectTimeout=5 "$h" \
    "wc -l /etc/wireguard/routes.batch 2>/dev/null || echo 'no routes.batch'" \
    > "$TMPDIR/$h/routes.batch.info" 2>/dev/null || true
done

tar -czf "$ARCHIVE" -C "$TMPDIR" .

# Кладём архив на оба хоста в /var/backups/vpn/
for h in "${REMOTE_HOSTS[@]}"; do
  ssh -o ConnectTimeout=5 "$h" "sudo -A mkdir -p $BACKUP_ROOT && \
    sudo -A cp -a $ARCHIVE $BACKUP_ROOT/ && \
    sudo -A chmod 600 $BACKUP_ROOT/$(basename $ARCHIVE)" 2>/dev/null && \
    echo "  → $h:$BACKUP_ROOT/$(basename $ARCHIVE)" || \
    echo "  ✗ не удалось положить на $h"
done

echo
echo "Архив: $ARCHIVE"
echo "Размер: $(du -h $ARCHIVE | cut -f1)"
echo
echo "⚠ ВНИМАНИЕ: архив содержит приватные ключи и PSK. Не публикуйте его."
echo "  Удалите после использования: shred -u $ARCHIVE"
