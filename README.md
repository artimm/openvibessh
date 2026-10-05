# openvibessh

Мини-скрипт выдачи SSH-доступа агентам (логин + пароль + sudo) в LXD-контейнерах. Без сертификатов и ключей — только логин и пароль.

## Режимы

Скрипт сам определяет, где запущен: на LXD-хосте (есть команда `lxc`) — режим **host**, внутри контейнера — режимы **agent** / **list**.

### 1. На хосте: показать контейнеры и открыть доступ

```bash
curl -fsSL https://raw.githubusercontent.com/artimm/openvibessh/main/openvibessh.sh -o ovssh.sh
bash ovssh.sh host
```

* Показывает **активные (RUNNING) LXD-контейнеры** — выбираете нужный.
* Спрашивает внешний порт (по умолчанию `2424`, проверяет занятость).
* Готовит `openssh-server` внутри контейнера (парольный вход разрешен).
* Добавляет проброс: `внешний порт хоста -> 22 контейнера`.

Аргументами: `bash ovssh.sh host <контейнер> <порт>`.

### 2. Внутри контейнера: выдать доступ агенту

```bash
curl -fsSL https://raw.githubusercontent.com/artimm/openvibessh/main/openvibessh.sh | bash -s -- agent <имя>
```

* Создает пользователя `<имя>` с **паролем** (или генерирует случайный).
* Выдает **sudo** на выбор: `NOPASSWD`, sudo с запросом пароля, или без sudo.
* Включает `sshd` на обычном порту **22** с парольной аутентификацией.
* Печатает готовую строку подключения.

### 3. Внутри контейнера: список выданных прав

```bash
curl -fsSL https://raw.githubusercontent.com/artimm/openvibessh/main/openvibessh.sh | bash -s -- list
```

Показывает журнал выданных доступов (`/etc/openvibessh/agents.list`) и эффективные права каждого агента (`sudo -l -U <имя>`).

## Подключение агента

```bash
ssh <имя>@<IP_хоста> -p <внешний порт>
```

## Отзыв доступа

Внутри контейнера: `userdel <имя> && rm /etc/sudoers.d/91-ovssh-<имя>` и удалить строку из `/etc/openvibessh/agents.list`. На хосте: `lxc config device remove <контейнер> ovssh-<порт>`.
