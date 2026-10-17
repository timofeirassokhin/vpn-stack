#!/usr/bin/env bash
# vpn-fix-obfuscation.sh — повторно применяет Jc/Jmin/Jmax/S1/S2/H1..H4 к awg0
#
# Использование: sudo bash vpn-fix-obfuscation.sh
#
# Проблема: amneziawg-tools v3.1 при awg-quick up молча отбрасывает параметры
# обфускации — они остаются в conf, но на live-интерфейсе их нет.
# Симптом: клиенты (телефон) подключаются, но handshake не сходится — tcpdump
# показывает входящие пакеты без ответа.
#
# Также устанавливает allowed-ips 0.0.0.0/0 для обоих пиров (фикс бага
# "awg set с несколькими пирами оставляет allowed_ips = (none)").

set -euo pipefail

WG_IF="${1:-awg0}"
SUDO="sudo -A"

if ! command -v "$SUDO" &>/dev/null; then
  SUDO="sudo"
fi

# 1. Применить Jc..H4
$SUDO /usr/local/bin/awg set "$WG_IF" jc 4 jmin 40 jmax 70 s1 43 s2 53 h1 1 h2 2 h3 3 h4 4
echo "✓ параметры обфускации применены к $WG_IF"

# 2. Для каждого пира из conf — allowed-ips 0.0.0.0/0
CONF="/etc/wireguard/${WG_IF}.conf"
if [[ ! -f "$CONF" ]]; then
  echo "✗ $CONF не найден"
  exit 1
fi

# Извлекаем все PublicKey из conf (только [Peer] секции)
mapfile -t PUBKEYS < <(awk '/^\[Peer\]/{flag=1; next} /\[/{flag=0} flag && /PublicKey/ {gsub(/.*= */, ""); print}' "$CONF")

for pk in "${PUBKEYS[@]}"; do
  $SUDO /usr/local/bin/awg set "$WG_IF" peer "$pk" allowed-ips 0.0.0.0/0
  echo "✓ allowed-ips 0.0.0.0/0 для пира $pk"
done

# 3. Проверить результат
echo
echo "=== текущее состояние $WG_IF ==="
$SUDO /usr/local/bin/awg show "$WG_IF"
