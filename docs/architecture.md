# Архитектура: tr-vps ↔ Miami

## Общая схема

```
┌──────────────────────────────────────────────────────────┐
│                      ИНТЕРНЕТ                            │
└──────────────────────────────────────────────────────────┘
       ▲                              ▲
       │ РФ-сайты                     │ зарубежные сайты
       │ (Яндекс, VK,                 │ (LinkedIn, FB,
       │  Госуслуги)                  │  Google, YouTube)
       │                              │
       │         ┌────────────────┐   │
       │         │   МАГИСТРАЛЬ   │   │
       │         │ 186.246.1.61   │   │
       │         │   tr-vps (РФ)  │   │
       │         └────────────────┘   │
       │              ▲    ▲          │
       │              │    │          │
       │              │    └──── awg1 (10.66.1.0/24) ────┐
       │              │              │                   │
       │              │            split-routing        │
       │              │             по MARK 0x10000     │
       │              │                                │
       │              │ eth0                            │
       │              │                                │
       │         ┌────┴────┐                           │
       │         │  awg0   │                           │
       │         │10.66.3.0│                           │
       │         │   /24   │                           │
       │         └─────────┘                           │
       │              ▲                                │
       │              │ AmneziaWG (UDP 51821)           │
       │              │ Jc=4, H1..H4 обфускация         │
       │              │                                │
       │   ┌──────────┴──────────┐                     │
       │   │                     │                     │
       │  Телефон              Ноут                     │
       │  (МТС)               (Wi-Fi)                  │
       │  10.66.3.3/32         10.66.3.2/32             │
       │                                                │
       │                                                │
       │   ┌─────────────────────────────────┐         │
       │   │  45.32.164.69 (Miami, US)        │◄────────┘
       │   │  enp1s0: 45.32.164.69            │
       │   │  awg1: 10.66.1.1/24              │
       │   │  MASQUERADE 10.66.0.0/24         │
       │   └─────────────────────────────────┘
       │
       └─► выход в РФ через eth0 провайдера
```

## Поток пакета (телефон → linkedin.com)

1. **Телефон** отправляет TCP SYN к `linkedin.com` (151.101.65.69).
   - `src = 10.66.3.3`
   - `dst = 151.101.65.69`
   - Внутри AmneziaWG-инкапсуляции (Jc=4, H1..H4 обфускация) → UDP на 186.246.1.61:51821.

2. **tr-vps**, интерфейс `awg0`, принимает.
   - awg разворачивает обфускацию и шифрование.
   - `src = 10.66.3.3, dst = 151.101.65.69`.

3. **mangle PREROUTING**:
   - `MARK 0x10000` ставится, потому что пакет пришёл с `awg0` и `dst != 10.66.3.0/24`.

4. **routing**:
   - `rule 50: from all fwmark 0x10000 lookup 200`.
   - `table 200` имеет `default via 10.66.1.1 dev awg1` (Miami).
   - 151.101.65.69 ∉ 10.66.0.0/24, поэтому пакет идёт в awg1.

5. **iptables FORWARD**:
   - Правило `-A FORWARD -i awg0 -j ACCEPT` пропускает.
   - `FORWARD awg0→awg1` = +1.

6. **nat POSTROUTING**:
   - `MASQUERADE 10.66.3.0/24` (или 10.66.0.0/24 — неважно, что первое сработает).
   - Но на этом этапе src не меняется, потому что пакет идёт в awg1, а не в eth0.

7. **awg1** инкапсулирует пакет → UDP на 45.32.164.69:51830 (Miami).

8. **Miami**, интерфейс `awg1`, принимает.
   - awg разворачивает.
   - `src = 10.66.1.2 (tr-vps awg1), dst = 151.101.65.69`.
   - Маршрут на дефолт через `enp1s0` (NAT на Miami).

9. **Miami iptables FORWARD + MASQUERADE**:
   - `MASQUERADE 10.66.0.0/24 → enp1s0` (более общее правило).
   - Пакет выходит в интернет с `src = 45.32.164.69`.

10. **linkedin.com** отвечает → 45.32.164.69.

11. **Miami** принимает ответ на `enp1s0` → `conntrack -L` → RELATED,ESTABLISHED.

12. **MASQUERADE** (un-NAT) → `src = 10.66.1.2, dst = 10.66.3.3`.

13. **awg1** инкапсулирует ответ → UDP на 10.66.1.2 (tr-vps).

14. **tr-vps** принимает на awg1.

15. **mangle PREROUTING**: пакет с dst=10.66.3.3, src=151.101.65.69 — connmark восстанавливается (если был) или не ставится.

16. **routing**: `route get 10.66.3.3` → `dev awg0 src 10.66.3.1` (через 10.66.3.0/24 dev awg0).

17. **iptables FORWARD**: `-A FORWARD -o awg0 -j ACCEPT` пропускает.

18. **awg0** инкапсулирует → UDP на 80.250.237.232:60000 (телефон).

19. **Телефон** получает ответ от linkedin.com.

## Ключевые таблицы и правила

### tr-vps

```
# Routing
10.66.1.0/24 dev awg1 proto kernel scope link src 10.66.1.2
10.66.3.0/24 dev awg0 proto kernel scope link src 10.66.3.1
186.246.1.0/24 dev eth0 proto kernel scope link src 186.246.1.61
default via 186.246.1.1 dev eth0

# ip rules
0: from all lookup local
50: from all fwmark 0x10000 lookup 200
100: from 10.66.3.0/24 lookup wg_user  # split-routing (РФ-подсети)
5210/5230/5250: Tailscale 100.82.2.78 lookup 52

# table 200 (зарубежный трафик)
default via 10.66.1.1 dev awg1

# table wg_user / 100 (split — 33 486 строк РФ-подсетей)
... все РФ-подсети через 186.246.1.1 ...
default via 10.66.1.1 dev awg1  # НЕ-РФ → Miami

# mangle PREROUTING
-A PREROUTING -i awg0 ! -d 10.66.3.0/24 -j MARK --set-mark 0x10000
-A PREROUTING -i tailscale0 -j CONNMARK --restore-mark --nfmask 0xff0000 --ctmask 0xff0000

# iptables FORWARD
-A FORWARD -i awg0 -j ACCEPT
-A FORWARD -o awg0 -j ACCEPT

# iptables nat POSTROUTING
-A POSTROUTING -s 10.66.3.0/24 ! -d 10.66.3.0/24 -j MASQUERADE
```

### Miami

```
# Routing
10.66.1.0/24 dev awg1 proto kernel scope link src 10.66.1.1
45.32.164.0/24 dev enp1s0 proto kernel scope link src 45.32.164.69
default via <gateway> dev enp1s0

# iptables FORWARD
-A FORWARD -i awg1 -j ACCEPT
-A FORWARD -o awg1 -j ACCEPT

# iptables nat POSTROUTING
-A POSTROUTING -s 10.66.0.0/24 -o enp1s0 -j MASQUERADE
```

## Что ломает эту схему

| Что                                     | Что происходит                                                | Фикс                                |
|----------------------------------------|--------------------------------------------------------------|--------------------------------------|
| `awg-quick up` отбрасывает обфускацию  | Клиенты не подключаются (handshake = 0)                       | `awg set` руками или PostUp          |
| `allowed_ips` пира Miami = 10.66.1.0/24 | Пакеты 10.66.3.3 → 8.8.8.8 дропаются                        | `allowed-ips 0.0.0.0/0`              |
| testns с veth на 10.66.3.3             | Обратный трафик уходит в testns                               | `ip netns delete testns`             |
| routes.batch загружен ДО awg0          | Клиентский трафик не маршрутизируется                         | `After=awg-quick@awg0.service`       |
| mark 0x10000 конфликтует с Tailscale   | Пакеты Tailscale идут через Miami и наоборот                  | Использовать уникальный mark         |
| `MASQUERADE 10.66.3.0/24` = 0          | Ложная тревога — NAT через 10.66.0.0/24                      | Проверить tcpdump                    |
