#!/usr/bin/env bash
# /etc/wireguard/iptables.sh — идемпотентное применение правил для awg0
#
# Использование: sudo bash iptables.sh [up|down]
# В PostUp awg0.conf вызывается логика; этот скрипт — для ручного применения и для понимания.

set -euo pipefail

ACTION="${1:-up}"
WG_IF="awg0"
CLIENT_NET="10.66.3.0/24"

case "$ACTION" in
  up)
    # FORWARD: разрешаем трафик клиентов
    iptables -C FORWARD -i "$WG_IF" -j ACCEPT 2>/dev/null || \
      iptables -A FORWARD -i "$WG_IF" -j ACCEPT
    iptables -C FORWARD -o "$WG_IF" -j ACCEPT 2>/dev/null || \
      iptables -A FORWARD -o "$WG_IF" -j ACCEPT

    # MASQUERADE: клиентский трафик наружу (выходит в awg1 к Miami или eth0 к РФ)
    iptables -t nat -C POSTROUTING -s "$CLIENT_NET" ! -d "$CLIENT_NET" -j MASQUERADE 2>/dev/null || \
      iptables -t nat -A POSTROUTING -s "$CLIENT_NET" ! -d "$CLIENT_NET" -j MASQUERADE

    echo "iptables: правила для $WG_IF применены"
    ;;

  down)
    iptables -D FORWARD -i "$WG_IF" -j ACCEPT 2>/dev/null || true
    iptables -D FORWARD -o "$WG_IF" -j ACCEPT 2>/dev/null || true
    iptables -t nat -D POSTROUTING -s "$CLIENT_NET" ! -d "$CLIENT_NET" -j MASQUERADE 2>/dev/null || true
    echo "iptables: правила для $WG_IF удалены"
    ;;

  *)
    echo "Использование: $0 [up|down]"
    exit 1
    ;;
esac
