# vpn-stack

Рабочая конфигурация VPN-стека: **tr-vps (РФ) ↔ Miami (US)** с split-routing и обходом DPI для устройств в РФ.

## Что это

- **tr-vps** (`186.246.1.61`) — входная точка в РФ, обход DPI через **AmneziaWG** (H1–H4 обфускация).
- **Miami** (`45.32.164.69`) — выход в США.
- **gluvex** (`45.66.117.251`) — отдельный xray REALITY `:8443`, в этом стеке не используется.

### Архитектура трафика

```
[Телефон/Ноут в РФ]
        │  AmneziaWG (Jc=4, H1..H4 обфускация, UDP 51821)
        ▼
   [tr-vps: awg0]  10.66.3.0/24
        │
        │  split-routing по fwmark 0x10000
        │
        ├── РФ-адреса ──► eth0 (напрямую через провайдера)
        │
        └── не-РФ ──► awg1 (10.66.1.0/24) ──► [Miami: enp1s0] ──► интернет
```

- **Таблица маршрутов** на tr-vps: `routes.batch` — 33 486 строк РФ-подсетей, `table wg_user` (id 100).
- **mangle PREROUTING**: пакеты с `awg0` (кроме локальной сети) получают `MARK 0x10000`.
- **ip rule 50**: `from all fwmark 0x10000 lookup 200` — зарубежный трафик → `awg1`.
- **ip rule 100**: `from 10.66.3.0/24 lookup wg_user` — основная split-таблица.

## Структура репозитория

```
vpn-stack/
├── README.md                  # этот файл — диагностика, архитектура, известные баги
├── configs/
│   ├── tr-vps/
│   │   ├── awg0.conf          # входной туннель (телефон/ноут)
│   │   ├── awg1.conf          # туннель до Miami
│   │   ├── routes.batch       # РФ-подсети (33 486 строк)
│   │   ├── iptables.sh        # FORWARD + MASQUERADE + mangle MARK
│   │   └── post-apply.sh      # применяет PostUp-политики
│   └── miami/
│       └── awg1-trvps.conf    # peer tr-vps, AllowedIPs 0.0.0.0/0
├── scripts/
│   ├── vpn-health.sh          # диагностика состояния (handshake, transfer, mark, route)
│   ├── vpn-fix-obfuscation.sh # повторно применяет Jc/H1..H4 после awg-quick restart
│   ├── vpn-backup.sh          # бэкап конфигов
│   └── vpn-restore.sh         # восстановление
└── docs/
    ├── troubleshooting.md     # типовые баги и фиксы
    ├── known-issues.md        # amneziawg-tools v3.1 quirks
    └── key-rotation.md        # процедура ротации ключей
```

## Сеть и IP

| Узел      | Внешний IP        | Внутренние IP awg          | Роль                |
|-----------|-------------------|----------------------------|---------------------|
| tr-vps    | 186.246.1.61      | 10.66.3.1 (awg0), 10.66.1.2 (awg1) | вход + сплит        |
| Miami     | 45.32.164.69      | 10.66.1.1 (awg1)           | выход в США         |
| Телефон   | 80.250.237.232:*  | 10.66.3.3/32               | клиент AmneziaWG    |
| Ноут      | динамический      | 10.66.3.2/32               | клиент AmneziaWG    |

## Версии

- **amneziawg-tools v3.1** на обоих серверах (`/usr/local/bin/awg`, `/usr/local/bin/awg-quick`).
- Tailscale на tr-vps (`100.82.2.78`, table 52) — **не трогать**.
- Docker на tr-vps — `amneziawg-server` отдельно (52431/udp, 10.10.10.0/24), **другая сеть**, не путать с нашим awg0.

## Запуск

1. На tr-vps: `sudo /usr/local/bin/awg-quick up awg0` → затем `sudo /usr/local/bin/awg-quick up awg1`.
2. Если handshake не сходится: `bash scripts/vpn-fix-obfuscation.sh` (см. ниже — баг v3.1).
3. На Miami: `sudo /usr/local/bin/awg-quick up awg1`.
4. Проверить: `bash scripts/vpn-health.sh`.

## Известные баги и фиксы — коротко

- **`awg-quick up` v3.1 молча отбрасывает Jc/Jmin/Jmax/S1/S2/H1–H4** — параметры применяются только в conf, но в runtime интерфейс остаётся без обфускации. → `awg set awg0 jc 4 jmin 40 jmax 70 s1 43 s2 53 h1 1 h2 2 h3 3 h4 4` руками после `up`.
- **`awg set` при нескольких пирах**: `allowed-ips` иногда ставится `(none)`, нужно ставить **только нужному пиру** отдельной командой и **дублировать в PostUp**.
- **H1–H4 в `awg show` не отображаются** — это особенность v3.1, **но работают**.
- **allowed_ips на пире Miami на tr-vps должны быть `0.0.0.0/0`** (а не `10.66.1.0/24`), иначе awg дропает пакеты `10.66.3.3 → 8.8.8.8` с `Required key not available`.
- **allowed_ips на пире tr-vps на Miami должны быть `0.0.0.0/0`** (а не `10.66.1.2/32, 10.66.3.0/24`), иначе awg на входе дропает пакеты по dst.
- **testns с veth на 10.66.3.3** — артефакт прошлой сессии, перехватывает обратный трафик, симптом — `local 10.66.3.3 dev veth0` в `ip route show table local`. **Удалить**: `ip link delete veth0 && ip netns delete testns`.
- **MASQUERADE счётчик может показывать 0** — пакеты всё равно маскарадяся через более общее правило (`10.66.0.0/24 → enp1s0`). Проверять по факту tcpdump на исходящем интерфейсе.

Подробности — в `docs/troubleshooting.md`.
