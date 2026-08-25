# Telegram Web Proxy Installer

Автоматическая установка **Telegram Web Proxy** на VPS под управлением **Debian 12+ / Ubuntu 22.04+ (x86_64)**.

Стек: **Caddy** (HTTPS/TLS) → **tproxy-server relay** → **официальный MTProxy**.

## Быстрый старт

Скачать и запустить одной командой:

```bash
curl -fsSL https://raw.githubusercontent.com/qwerokip-wq/install-twebproxy/main/install-twebproxy.sh -o install-twebproxy.sh
chmod +x install-twebproxy.sh
sudo ./install-twebproxy.sh --domain proxy.example.com --email admin@example.com
```

Секрет сгенерируется автоматически. На выходе — готовая ссылка для Telegram:
`https://t.me/webproxy?server=proxy.example.com&secret=<ваш_секрет>`

## Требования

- **ОС:** Debian 12+ или Ubuntu 22.04+ (x86_64)
- **Доступ:** root (`sudo`)
- **Домен:** A-запись, указывающая на IP вашего VPS
- **Порты:** 80 и 443 должны быть свободны (или заняты Caddy)

## Все опции

```
Usage: sudo ./install-twebproxy.sh --domain HOST --email ADDRESS [options]

Обязательные:
  --domain HOST          Имя хоста (A-запись указывает на этот VPS)
  --email ADDRESS        Контактный email для ACME (Let's Encrypt)

Опции:
  --secret HEX           Секрет клиента: 32 hex или dd+32 hex
                         Если не указан — генерируется автоматически
  --workers N            Рабочих процессов MTProxy (default: 1, макс. 256)
  --max-connections N    Лимит соединений MTProxy на воркер (default: 4096)
  --site-dir DIR         Статический сайт оператора вместо заглушки
  --site-upstream URL    http://127.0.0.1:PORT локального приложения
  --site-csp STRING      Content-Security-Policy для сайта оператора
                         (заменяет строгий дефолт relay)
  --skip-dns-check       Не сверять DNS с публичным IP VPS
  -h, --help             Показать справку
```

## Примеры

**Минимальная установка (автосекрет):**
```bash
sudo ./install-twebproxy.sh --domain proxy.example.com --email admin@example.com
```

**Установка со своим секретом:**
```bash
sudo ./install-twebproxy.sh --domain proxy.example.com --email admin@example.com --secret 000102030405060708090a0b0c0d0e0f
```

**Установка со своим сайтом (статическая директория):**
```bash
sudo ./install-twebproxy.sh --domain proxy.example.com --email admin@example.com --site-dir ./my-site
```

**Установка с сайтом-приложением и CSP для HTML5-игры:**
```bash
sudo ./install-twebproxy.sh --domain game.example.com --email admin@example.com --site-dir ./game --site-csp "default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; media-src 'self' blob: data:; font-src 'self' data:; connect-src 'self' blob:; worker-src 'self' blob:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
```

**Установка с upstream-приложением (локальный веб-сервер):**
```bash
sudo ./install-twebproxy.sh --domain proxy.example.com --email admin@example.com --site-upstream http://127.0.0.1:3000
```

## Удаление

```bash
sudo ./uninstall-twebproxy.sh
```

Для удаления без подтверждения:
```bash
sudo ./uninstall-twebproxy.sh --force
```

Скрипт сохраняет предсуществующие компоненты (Caddy, MTProxy, relay), если они были установлены ранее.

## Используемые компоненты

| Компонент | Назначение | Ссылка |
|-----------|-----------|--------|
| **Caddy** | HTTPS-терминация, автоматические TLS-сертификаты через Let's Encrypt | [caddyserver.com](https://caddyserver.com/) |
| **tproxy-server** | Relay-сервер Telegram Web Proxy (WebView → MTProxy bridge) | [telegramdesktop/tproxy-server](https://github.com/telegramdesktop/tproxy-server) |
| **MTProxy** | Официальный MTProto-прокси Telegram | [TelegramMessenger/MTProxy](https://github.com/TelegramMessenger/MTProxy) |

## Примечание о CSP

По умолчанию relay tproxy-server добавляет строгий Content-Security-Policy на все статические ответы. Если ваш сайт использует inline-скрипты, `eval()` или WebSocket-соединения, передайте ослабленный CSP через опцию `--site-csp`.

## Лицензия

MIT
