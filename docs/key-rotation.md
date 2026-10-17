# Key Rotation

## Зачем

В процессе диагностики VPN-стека (октябрь 2026) приватные ключи и PSK мелькали в `awg show`, tcpdump, debug-выводах. **Рекомендуется ротация** перед публикацией любых связанных артефактов.

## Какие ключи менять

| Хост     | Что                                         | Пара ключей          |
|----------|---------------------------------------------|----------------------|
| tr-vps   | awg0 (вход) + awg1 (к Miami)                | 2 PrivateKey + 4 PSK |
| Miami    | awg1 (peer tr-vps)                          | 1 PrivateKey + 1 PSK |
| Ноут     | клиент                                      | 1 PrivateKey + 1 PSK |
| Телефон  | клиент                                      | 1 PrivateKey + 1 PSK |

Итого: **5 PrivateKey + 7 PSK = 12 секретов**.

## Процедура

### 1. Сгенерировать новые ключи

```bash
# На tr-vps
for i in 1 2 3 4 5; do
  /usr/local/bin/awg genkey | tee /tmp/priv-$i | /usr/local/bin/awg pubkey > /tmp/pub-$i
done
# То же на Miami (ещё 1)
```

Для **PSK** (общий для обоих сторон):
```bash
# На tr-vps
/usr/local/bin/awg genpsk > /tmp/psk-trvps-awg0-phone
/usr/local/bin/awg genpsk > /tmp/psk-trvps-awg0-laptop
/usr/local/bin/awg genpsk > /tmp/psk-trvps-awg1-miami
# На Miami
/usr/local/bin/awg genpsk > /tmp/psk-miami-awg1-trvps
```

### 2. Обновить conf-файлы

**tr-vps** (`/etc/wireguard/awg0.conf`):
- Заменить свой PrivateKey в `[Interface]`.
- Заменить PublicKey пиров (laptop, phone) на **публичные** ключи клиентов (а не свои).
- Заменить PresharedKey пиров на новые.

**tr-vps** (`/etc/wireguard/awg1.conf`):
- Свой PrivateKey.
- PublicKey Miami — публичный ключ нового PrivateKey Miami.
- PresharedKey — общий с Miami.

**Miami** (`/etc/wireguard/awg1-trvps.conf`):
- Свой PrivateKey.
- PublicKey tr-vps — публичный ключ нового PrivateKey tr-vps awg1.
- PresharedKey — общий.

**Клиенты** (ноут, телефон):
- Заменить свой PrivateKey, PublicKey сервера на новые, PresharedKey на новые.

### 3. Применить

```bash
# На tr-vps
sudo /usr/local/bin/awg-quick down awg0
sudo /usr/local/bin/awg-quick up awg0
sudo /usr/local/bin/awg-quick down awg1
sudo /usr/local/bin/awg-quick up awg1

# На Miami
sudo /usr/local/bin/awg-quick down awg1
sudo /usr/local/bin/awg-quick up awg1
```

**Клиенты** переподключатся автоматически (если endpoint не менялся).

### 4. Проверить

```bash
bash scripts/vpn-health.sh
# handshake должен пройти в течение 1-2 минут
```

### 5. Старые ключи — в черный список

Старые PrivateKey теперь **считаются скомпрометированными**. Даже если новый стек работает, **любой**, кто увидел старые ключи в логах, может:

- Подключиться к awg0 с **чужим** PublicKey и **общим** PresharedKey — если узнал psk. Чужих подключений не будет, если PublicKey не утек.
- Подделать endpoint и перехватить трафик.

**Действие**: убедиться, что **нигде** в публичных местах (Slack, Telegram, Notion, GitHub Issues) нет старых ключей. Если есть — **ротация обязательна**.

## Что НЕ считается утечкой

- Публичные ключи (`PublicKey` пиров) — они публичные по определению.
- `AllowedIPs`, `Endpoint`, IP-адреса.
- Параметры обфускации (`Jc`, `H1..H4`).

## Что считается

- `PrivateKey` в `[Interface]` и `PresharedKey` в `[Peer]` — **НИКОГДА не коммитить в git**.
- ВСЕ упоминания `[REDACTED]` в этом репо — это **плейсхолдеры** для удобства чтения, реальные ключи должны быть **только** в `/etc/wireguard/*.conf` на серверах и клиентах.
