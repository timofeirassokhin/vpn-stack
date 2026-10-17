# Troubleshooting

Типовые симптомы и фиксы. Отсортировано по частоте.

## 1. «Телефон подключён, но трафик не идёт»

**Симптомы**:
- `awg show awg0 transfer` показывает 100+ KB rx, <10 KB sent.
- DNS не резолвится, сайты не открываются.
- `MARK 0x10000` большой, `FORWARD awg0→awg1` большой, но `MASQUERADE 10.66.3.0/24 -o awg1` = 0.

**Фикс 1 (Miami)**:
```bash
ssh miami
sudo /usr/local/bin/awg set awg1 peer <tr-vps-pubkey> allowed-ips 0.0.0.0/0
# и поправить /etc/wireguard/awg1-trvps.conf: AllowedIPs = 0.0.0.0/0
```

**Фикс 2 (tr-vps, testns-призрак)**:
```bash
ip route show table local | grep 10.66.3
# если "dev veth" — это testns из прошлой сессии:
ip link delete veth0
ip netns delete testns
# затем перезапустить awg0:
sudo /usr/local/bin/awg-quick down awg0 && sudo /usr/local/bin/awg-quick up awg0
```

## 2. «Телефон вообще не подключается, handshake = 0»

**Симптомы**:
- `awg show awg0` показывает 0 handshake, 0 transfer.
- `ss -ulpn | grep 51821` — порт слушается.
- `tcpdump -i eth0 -n 'udp port 51821'` — входящие пакеты от клиента есть, ответов нет.

**Причина**: `awg-quick up` v3.1 отбросил параметры обфускации.

**Фикс**:
```bash
sudo /usr/local/bin/awg set awg0 jc 4 jmin 40 jmax 70 s1 43 s2 53 h1 1 h2 2 h3 3 h4 4
# 1-2 минуты, и handshake должен пройти.
```

Или запустить `bash scripts/vpn-fix-obfuscation.sh`.

**Превентивно**: добавить в PostUp conf отдельной строкой:
```
PostUp = /usr/local/bin/awg set %i jc 4 jmin 40 jmax 70 s1 43 s2 53 h1 1 h2 2 h3 3 h4 4
```

## 3. «allowed_ips у пира = (none)»

**Симптомы**:
- `awg show awg0` показывает у одного из пиров `allowed ips: (none)`.
- Этот пир не работает.

**Причина**: при `awg set` с несколькими пирами `allowed-ips` иногда устанавливается только одному.

**Фикс**: ставить allowed-ips **отдельной командой для каждого пира**:
```bash
sudo /usr/local/bin/awg set awg0 peer <pk1> allowed-ips 0.0.0.0/0
sudo /usr/local/bin/awg set awg0 peer <pk2> allowed-ips 0.0.0.0/0
```

## 4. «tcpdump на Miami awg1 показывает 0 при работающем ping»

**Причина**: race condition. tcpdump запускается/останавливается **не в момент пинга**.

**Фикс**: запускать tcpdump **параллельно и держать открытым дольше пинга**:
```bash
ssh miami "sudo timeout 12 tcpdump -i awg1 -n" &
sleep 1
ssh tr-vps "sudo ping -I 10.66.3.3 -c 5 8.8.8.8"
wait
```

## 5. «MASQUERADE-счётчик = 0, но NAT работает»

**Симптом**: `iptables -t nat -L POSTROUTING -n -v` показывает 0 для `10.66.3.0/24 → enp1s0`, но более общее правило `10.66.0.0/24 → enp1s0` имеет миллионы пакетов.

**Причина**: правило `10.66.3.0/24` никогда не срабатывает, потому что пакет попадает в первое подходящее правило `10.66.0.0/24`. **Это не баг, NAT работает**.

**Проверка**: tcpdump на enp1s0 (out) — если src = 45.32.164.69, то NAT работает.

## 6. «Что-то сломалось, не знаю что»

Запустить диагностику:
```bash
bash scripts/vpn-health.sh
```

Покажет: версию, обфускацию, handshake, transfer, mangle MARK, FORWARD-счётчики, ping-тест, transfer Miami, проверку на testns-призрак.
