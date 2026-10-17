# Known Issues

Задокументированные особенности amneziawg-tools, ядра Linux, и окружения.

## amneziawg-tools v3.1

### Баг 1: `awg-quick up` отбрасывает параметры обфускации

`Jc`, `Jmin`, `Jmax`, `S1`, `S2`, `H1..H4` при `awg-quick up` **не применяются к live-интерфейсу**, хотя остаются в conf-файле. Симптом: клиенты шлют пакеты (видно по tcpdump), но handshake не сходится.

**Обход**:
- В conf добавить PostUp:
  ```
  PostUp = /usr/local/bin/awg set %i jc 4 jmin 40 jmax 70 s1 43 s2 53 h1 1 h2 2 h3 3 h4 4
  ```
- Или запустить `scripts/vpn-fix-obfuscation.sh` после `awg-quick up`.

### Баг 2: H1..H4 в `awg show` не отображаются

После `awg set %i h1 1 h2 2 h3 3 h4 4` в выводе `awg show` параметры H1..H4 **отсутствуют**. Проверить, что применились, можно только косвенно — по прошедшему handshake. **Это особенность отображения, не баг функциональности**.

### Баг 3: `awg set` с несколькими пирами — `allowed_ips = (none)`

`awg set %i peer <pk1> allowed-ips 0.0.0.0/0` при наличии нескольких пиров иногда **оставляет allowed_ips = (none)**. Фикс — устанавливать `allowed-ips` **для каждого пира отдельной командой**.

### Баг 4: `awg set` возвращает `(none)` сразу после `up`

В первые секунды после `awg-quick up` `awg show` может показывать `allowed ips: (none)`. Это проходит через 1-2 секунды. Если остаётся — применять ручной `awg set`.

## Ядро Linux: local table и namespace

### Проблема: другой netns занял IP пира

Если в `ip route show table local` есть запись вида:
```
local 10.66.3.3 dev veth0 proto kernel scope host src 10.66.3.3
```

…то kernel считает `10.66.3.3` **локальным адресом** в этом netns, и пакеты с этим dst **не маршрутизируются в awg0**.

**Решение**: либо удалить namespace (`ip netns delete <name>`), либо выбрать другой IP для пира.

**Профилактика**: перед `awg-quick up` всегда проверять:
```bash
ip route show table local | grep 10.66
ip netns list
```

## iptables: счётчики и NAT

### Ложная тревога: `MASQUERADE <subnet> = 0`

Если есть два правила: `10.66.0.0/24 → MASQUERADE` и `10.66.3.0/24 → MASQUERADE`, то второе **никогда не сработает** — пакет попадает в первое подходящее. Счётчик `10.66.3.0/24` остаётся 0, но NAT работает через `10.66.0.0/24`.

**Проверка**: tcpdump на out-интерфейсе с фильтром по `src = $external_ip` — если пакет уходит, NAT работает.

### `mangle PREROUTING` не срабатывает на локальные пакеты

`ping -I 10.66.3.3 8.8.8.8` **генерирует пакет на tr-vps** и идёт через `OUTPUT`/`POSTROUTING`, минуя `mangle PREROUTING`. Поэтому `MARK 0x10000` = 0 для таких пакетов — **это не баг**.

Для проверки **реального трафика клиента** — смотреть счётчики `FORWARD` и tcpdump на `awg0` (вход).

## Tailscale: не сломать

Tailscale на tr-vps использует `100.82.2.78`, `table 52`, правила 5210/5230/5250. **mark 0x80000 = Tailscale**. Наш mark `0x10000` не пересекается.

**Перед любыми правками** сохранить состояние:
```bash
ip rule show > /tmp/iptables-snapshot.bak
ip route show table 52 > /tmp/ts-table.bak
iptables-save > /tmp/iptables-save.bak
```

## systemd-юниты: порядок загрузки

`wg-quick@.service` (или `awg-quick@.service`) поднимает интерфейс **до загрузки routes.batch**. Если routes.batch устанавливается отдельным юнитом (`/etc/systemd/system/routes-load.service`), он должен зависеть от `awg-quick@awg0.service`.

**Если routes.batch загружается ДО поднятия awg0** — пакеты от клиентов не маршрутизируются (нет маршрута к 10.66.3.0/24 через awg0). Фикс: `After=awg-quick@awg0.service` в `routes-load.service`.
