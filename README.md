# Snake VPN

<p align="center">
  <img src="logo.png" width="150" alt="Snake VPN">
</p>

## Что это такое

Snake VPN — это персональный VPN-сервер, который вы разворачиваете на своём VPS. Главное отличие от обычных VPN — **полная невидимость для систем блокировок**.

Обычный VPN (WireGuard, OpenVPN) легко обнаруживается и блокируется провайдерами и государственными фильтрами — у них характерный протокол, который системы DPI (Deep Packet Inspection) распознают за секунду.

Snake VPN работает иначе: весь трафик идёт **внутри обычного HTTPS-соединения** через WebSocket на стандартном порту 443. Для любого наблюдателя — провайдера, DPI-системы, файрвола — это выглядит как будто вы просто заходите на обычный сайт. Потому что сервер **действительно работает как обычный сайт** — при открытии в браузере показывает веб-страницу, отвечает заголовками nginx, ведёт себя как тысячи других сайтов в интернете.

## Как это работает

```
Вы                         Наблюдатель видит               Сервер
 │                                                           │
 │  ── HTTPS на порт 443 ──────────────────────────────────► │
 │     (обычный сайт)         "Пользователь зашёл            │
 │                             на сайт example.com"          │
 │  ◄─ Веб-страница ───────────────────────────────────────  │
 │                                                           │
 │  ── WebSocket (внутри того же HTTPS) ──────────────────► │
 │     VPN-туннель             "Пользователь смотрит         │
 │     зашифрованный           контент на сайте"             │ ──► Интернет
 │     бинарный протокол                                     │
 │     + паддинг                                             │
 │  ◄─────────────────────────────────────────────────────── │
 │
```

**Три уровня маскировки:**

1. **Протокол** — VPN-трафик упакован в WebSocket внутри TLS. Снаружи — стандартный HTTPS, порт 443. Ничем не отличается от посещения любого сайта.

2. **Камуфляж** — если кто-то (DPI-система, цензор, просто любопытный) откроет адрес сервера в браузере — увидит обычный сайт. Сервер отвечает заголовками `nginx/1.24.0`, отдаёт HTML-страницы. Никаких признаков VPN.

3. **Паддинг** — к каждому пакету добавляются случайные байты, чтобы пакеты были разного размера. Это ломает статистический анализ трафика — ещё один метод, которым DPI пытается вычислить VPN.

## Из чего состоит

| Компонент | Что делает | Платформы |
|-----------|------------|-----------|
| **Сервер** | Стоит на вашем VPS. Принимает VPN-подключения, маскируется под сайт, управляет ключами | Linux |
| **Менеджер** | Приложение для администратора. Подключается к серверу, создаёт ключи доступа, показывает статистику | Android, Windows |
| **Клиент** | Приложение для пользователя. Получает ключ от администратора, подключается к VPN | Android, Windows |

**Схема использования (как Outline):**

1. Администратор разворачивает сервер → получает **админ-токен**
2. Администратор открывает Менеджер → вводит адрес сервера + админ-токен
3. В Менеджере создаёт **ключи доступа** для пользователей
4. Каждый ключ — это ссылка `svpn://...`, которую отправляет пользователю
5. Пользователь открывает Клиент → вставляет ключ → подключается

## Что для этого нужно

- **VPS** (виртуальный сервер) с Linux — подойдёт любой за $3-5/мес (Hetzner, DigitalOcean, Oracle Cloud Free Tier и т.д.)
- **Доменное имя** — нужно для SSL-сертификата (Let's Encrypt выдаёт бесплатно). Домен должен указывать на IP вашего VPS
- **Открытые порты**: 443 (HTTPS) и 80 (для получения сертификата)
- На VPS нужен root-доступ и Linux (Ubuntu, Debian, CentOS)

**Не нужно:** никаких знаний программирования, никаких дополнительных сервисов, никакой ежемесячной оплаты (кроме VPS)

---

## Установка

Все файлы скачиваются со страницы [Releases](https://github.com/4eSyH/snake-vpn/releases):

| Файл | Что это |
|------|---------|
| `silent-vpn-server-linux-amd64` | Сервер для Linux x86_64 |
| `silent-vpn-server-linux-arm64` | Сервер для Linux ARM64 (Oracle Cloud и т.д.) |
| `silent-vpn-client.apk` | Клиент для Android |
| `silent-vpn-client.msix` | Клиент для Windows |
| `silent-vpn-manager.apk` | Менеджер для Android |
| `silent-vpn-manager.msix` | Менеджер для Windows |

---

## Шаг 1. Развернуть сервер

Подключиться к VPS по SSH и выполнить:

```bash
# Скачать сервер
wget https://github.com/4eSyH/snake-vpn/releases/latest/download/silent-vpn-server-linux-amd64
chmod +x silent-vpn-server-linux-amd64
sudo mv silent-vpn-server-linux-amd64 /usr/local/bin/silent-vpn

# Создать директории
sudo mkdir -p /etc/silent-vpn /var/lib/silent-vpn/certs /var/log/silent-vpn /var/lib/silent-vpn/web

# Сгенерировать админ-токен — ЗАПИШИТЕ ЕГО, он понадобится дальше
openssl rand -hex 32
```

Создать конфиг:

```bash
sudo nano /etc/silent-vpn/server.yaml
```

Вставить (заменив 3 значения, отмеченные стрелками):

```yaml
server:
  listen: ":443"
  domain: "ваш-домен.com"           # ◄── ваш домен

tls:
  mode: "letsencrypt"
  acme_email: "ваш@email.com"       # ◄── ваш email (для Let's Encrypt)
  acme_cache_dir: "/var/lib/silent-vpn/certs"

auth:
  tokens: []
  secret_path: "/api/v2/events/stream"

tunnel:
  mtu: 1400
  keepalive_interval: 30
  keepalive_timeout: 90
  padding:
    enabled: true
    min_size: 0
    max_size: 256

network:
  subnet: "10.7.0.0/24"
  server_ip: "10.7.0.1"
  dns: ["1.1.1.1", "8.8.8.8"]
  nat_interface: "eth0"              # ◄── сетевой интерфейс (см. ниже)

camouflage:
  static_dir: "/var/lib/silent-vpn/web"
  index_file: "index.html"

logging:
  level: "info"
  file: "/var/log/silent-vpn/server.log"

management:
  admin_token: "ВСТАВЬТЕ_ТОКЕН"     # ◄── токен из шага выше
  key_store_path: "/var/lib/silent-vpn/keystore.json"
```

> **Как узнать nat_interface:** выполните `ip route | grep default`. В выводе будет что-то вроде `default via 10.0.0.1 dev eth0` — значит интерфейс `eth0`. На некоторых VPS может быть `ens3`, `enp0s3` и т.д.

Запустить сервер:

```bash
# Сайт-заглушка (или положите свой HTML-шаблон)
echo '<html><body><h1>Welcome</h1></body></html>' | sudo tee /var/lib/silent-vpn/web/index.html

# Защитить конфиг
sudo chmod 600 /etc/silent-vpn/server.yaml

# Включить IP forwarding
echo 'net.ipv4.ip_forward = 1' | sudo tee /etc/sysctl.d/99-vpn.conf
sudo sysctl -p /etc/sysctl.d/99-vpn.conf

# Создать systemd-сервис
sudo tee /etc/systemd/system/silent-vpn.service > /dev/null << 'EOF'
[Unit]
Description=Silent VPN Server
After=network.target
[Service]
Type=simple
ExecStart=/usr/local/bin/silent-vpn -config /etc/silent-vpn/server.yaml
Restart=on-failure
RestartSec=5
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF

# Запустить и включить автозапуск
sudo systemctl daemon-reload
sudo systemctl enable --now silent-vpn
```

Проверить что работает:

```bash
sudo systemctl status silent-vpn     # Должен быть active (running)
sudo journalctl -u silent-vpn -f     # Логи в реальном времени
```

Если открыть `https://ваш-домен.com` в браузере — должен показаться сайт-заглушка. Это значит сервер работает.

### Альтернатива: Docker

```bash
git clone https://github.com/4eSyH/snake-vpn.git && cd snake-vpn
cp server/configs/server.example.yaml server/configs/server.yaml
# Отредактировать server.yaml (домен, email, токен)
docker-compose up -d
```

---

## Шаг 2. Подключить менеджер

1. Скачать менеджер: [Android (.apk)](https://github.com/4eSyH/snake-vpn/releases) или [Windows (.msix)](https://github.com/4eSyH/snake-vpn/releases)
2. Открыть приложение
3. Ввести:
   - **URL сервера**: `https://ваш-домен.com`
   - **Админ-токен**: токен из конфига (`management.admin_token`)
4. Нажать **"Подключиться"**

Если всё верно — откроется панель управления с информацией о сервере.

---

## Шаг 3. Создать ключи для пользователей

В менеджере:

1. Перейти в раздел **"Ключи"**
2. Нажать **"Создать ключ"**
3. Ввести имя (например "Телефон Андрей", "Ноутбук мама")
4. При необходимости: задать лимит трафика или срок действия
5. Нажать **"Создать"**
6. Скопировать `svpn://` ссылку и отправить пользователю

Ключ выглядит так:
```
svpn://a1b2c3d4e5f6...@vpn.example.com:443/api/v2/events/stream#Телефон
```

Можно создать сколько угодно ключей — по одному на каждое устройство. Каждый ключ отслеживается отдельно: трафик, время подключения, активность.

---

## Шаг 4. Подключить клиент

1. Скачать клиент: [Android (.apk)](https://github.com/4eSyH/snake-vpn/releases) или [Windows (.msix)](https://github.com/4eSyH/snake-vpn/releases)
2. Скопировать `svpn://` ключ в буфер обмена
3. Открыть клиент — он автоматически предложит импортировать ключ
4. Нажать **кнопку подключения**

Всё. VPN работает.

---

## Обновление

**Клиент и менеджер** проверяют новые версии автоматически при запуске. Если есть обновление — покажут уведомление с кнопкой скачивания.

**Сервер** обновляется вручную:

```bash
wget https://github.com/4eSyH/snake-vpn/releases/latest/download/silent-vpn-server-linux-amd64
sudo mv silent-vpn-server-linux-amd64 /usr/local/bin/silent-vpn
sudo chmod +x /usr/local/bin/silent-vpn
sudo systemctl restart silent-vpn
```

---

## Дополнительно

### Режимы TLS

| Режим | Когда использовать |
|-------|--------------------|
| `letsencrypt` | **Рекомендуется.** Автоматический бесплатный сертификат. Нужен домен + порт 80 |
| `selfsigned` | Для тестов без домена. Клиент принимает такой сертификат по умолчанию |
| `manual` | Если уже есть сертификат (от certbot и т.д.). Сервер следит за файлами и обновляет без перезапуска |

### Камуфляж

Чем реалистичнее сайт-заглушка — тем лучше маскировка. Вместо `<h1>Welcome</h1>` положите в `/var/lib/silent-vpn/web/` любой HTML-шаблон: блог, лендинг, портфолио. Сервер будет отдавать его всем, кто зайдёт в браузере.

### Секретный путь

В конфиге `auth.secret_path` — это URL, по которому клиент подключается к VPN. Он должен выглядеть как обычный API-эндпоинт:

| Хорошо | Плохо |
|--------|-------|
| `/api/v2/events/stream` | `/vpn` |
| `/ws/notifications` | `/tunnel` |
| `/graphql/subscriptions` | `/connect` |

### Безопасность

- Весь трафик зашифрован TLS
- Токены сравниваются с защитой от timing-атак
- Хранилище ключей создаётся с правами только для root
- Сервер не выдаёт что это VPN — на любой неизвестный запрос отвечает сайтом
- Паддинг трафика затрудняет статистический анализ
