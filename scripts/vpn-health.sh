#!/usr/bin/env bash
# vpn-health.sh — диагностика VPN-стека tr-vps ↔ Miami
#
# Использование: bash vpn-health.sh
# Опционально: bash vpn-health.sh tr-vps  (хост по умолчанию)
#
# Проверяет:
#  - amneziawg-tools версию
#  - awg0: handshake, transfer, endpoints, обфускацию
#  - awg1: handshake, transfer, peer allowed_ips
#  - mangle MARK 0x10000 (счётчик)
#  - iptables FORWARD awg0↔awg1 + MASQUERADE
#  - routing: ip rule, table 200
#  - тестовый ping -I 10.66.3.3 1.1.1.1
#  - tcpdump на Miami awg1 (в течение 8 сек во время пинга)

set -uo pipefail

HOST="${1:-tr-vps}"
MIAMI="miami"
SUDO="sudo -A"

ok()  { printf "  \033[32m✓\033[0m %s\n" "$1"; }
err() { printf "  \033[31m✗\033[0m %s\n" "$1"; }
hdr() { printf "\n\033[1m== %s ==\033[0m\n" "$1"; }

# Цветной вывод для финального вердикта
verdict=0

ssh_run() {
  local h="$1"; shift
  ssh -o ConnectTimeout=5 "$h" "$@"
}

# 1. Версия amneziawg
hdr "amneziawg-tools версия"
V=$(ssh_run "$HOST" "/usr/local/bin/awg --version" 2>&1 | tail -1)
echo "  $V"

# 2. awg0 статус
hdr "awg0 ($HOST) — вход телефон/ноут"
SSH_ASKPASS="/tmp/_askpass.sh" ssh_run "$HOST" \
  "export SUDO_ASKPASS=/tmp/_askpass.sh; $SUDO /usr/local/bin/awg show awg0" 2>&1 | \
  awk '
    /listening port:/ { print "  port: "$3 }
    /jc:|jmin:|jmax:|s1:|s2:|h1:|h2:|h3:|h4:/ { print "  obfusc: "$0 }
    /latest handshake:/ { print "  handshake: "$0 }
    /transfer:/ { print "  transfer:  "$0 }
    /endpoint:/ { print "  endpoint:  "$2 }
  '

# 3. awg1 статус
hdr "awg1 ($HOST) — туннель к Miami"
ssh_run "$HOST" "export SUDO_ASKPASS=/tmp/_askpass.sh; $SUDO /usr/local/bin/awg show awg1" 2>&1 | \
  awk '
    /latest handshake:/ { print "  handshake: "$0 }
    /transfer:/ { print "  transfer:  "$0 }
    /endpoint:/ { print "  endpoint:  "$2 }
    /allowed ips:/ { print "  allowed_ips (peer Miami): "$0 }
  '

# 4. mangle MARK
hdr "mangle MARK 0x10000 (зарубежный трафик)"
MARK=$(ssh_run "$HOST" "export SUDO_ASKPASS=/tmp/_askpass.sh; $SUDO iptables -t mangle -L PREROUTING -n -v -x | awk '/0x10000/ {print \$1}' | head -1" 2>&1 | tr -d '\r')
if [[ -n "$MARK" && "$MARK" -gt 0 ]]; then
  ok "MARK = $MARK пакетов"
else
  err "MARK пусто (0) — никто не отправляет зарубежный трафик"
fi

# 5. iptables FORWARD
hdr "iptables FORWARD"
FWD=$(ssh_run "$HOST" "export SUDO_ASKPASS=/tmp/_askpass.sh; $SUDO iptables -L FORWARD -n -v -x | grep -E 'awg0|awg1' | head -4" 2>&1)
echo "$FWD" | sed 's/^/  /'

# 6. Routing
hdr "ip rule + table 200"
ssh_run "$HOST" "ip rule show | head -10" 2>&1 | sed 's/^/  /'
echo
ssh_run "$HOST" "ip route show table 200" 2>&1 | sed 's/^/  /'

# 7. Тестовый ping -I 10.66.3.3 1.1.1.1
hdr "тест ping 1.1.1.1 от имени клиента (10.66.3.3)"
PING_OUT=$(ssh_run "$HOST" \
  "export SUDO_ASKPASS=/tmp/_askpass.sh; $SUDO timeout 6 ping -I 10.66.3.3 -c 3 -W 2 1.1.1.1 2>&1 | tail -5" 2>&1)
echo "$PING_OUT" | sed 's/^/  /'
if echo "$PING_OUT" | grep -q " 0% packet loss"; then
  ok "ping 1.1.1.1 прошёл"
else
  err "ping 1.1.1.1 не прошёл — проверить mark/forward/MASQUERADE"
  verdict=1
fi

# 8. Miami awg1 transfer (нас интересует, доходят ли пакеты)
hdr "Miami awg1 transfer (пир tr-vps)"
MIAMI_TRANSFER=$(ssh_run "$MIAMI" "export SUDO_ASKPASS=/tmp/_askpass.sh; $SUDO /usr/local/bin/awg show awg1 transfer" 2>&1)
echo "$MIAMI_TRANSFER" | sed 's/^/  /'

# 9. local table — не висит ли testns-призрак
hdr "ip route show table local (проверка на testns-призрак)"
LOCAL=$(ssh_run "$HOST" "ip route show table local | grep '10.66.3'" 2>&1)
if echo "$LOCAL" | grep -q "dev veth"; then
  err "Найден veth0/testns с IP 10.66.3.3 — обратный трафик уходит в testns!"
  echo "  $LOCAL" | sed 's/^/    /'
  echo "  ФИКС: ip link delete veth0 && ip netns delete testns"
  verdict=1
else
  ok "testns-призрака нет, IP 10.66.3.3 чист для awg0"
fi

# Итог
echo
if [[ $verdict -eq 0 ]]; then
  printf "\033[32m→ VPN-стек выглядит работоспособно.\033[0m\n"
else
  printf "\033[31m→ VPN-стек требует вмешательства (см. ошибки выше).\033[0m\n"
fi
exit $verdict
