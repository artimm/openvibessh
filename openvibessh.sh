#!/usr/bin/env bash
# =====================================================
# OPENVIBESSH v1.5
# Выдача SSH-доступа агентам (логин + пароль + sudo) в LXD-контейнерах
# + планировщик TTL (автоотключение при простое)
#
# Автоопределение места запуска:
#   ХОСТ:      ./openvibessh.sh            - меню хоста (контейнеры/порты/агенты)
#              ./openvibessh.sh open [CT] [порт]  - сразу открыть доступ
#              ./openvibessh.sh ports             - список открытых портов
#              ./openvibessh.sh close             - закрыть доступ
#   КОНТЕЙНЕР: ./openvibessh.sh              - меню контейнера
#              ./openvibessh.sh agent <имя> [минут] [политика]
#              ./openvibessh.sh agent-add <имя> <пароль|-> <минуты> <политика> <no|askpass|nopasswd>
#              ./openvibessh.sh list | ttl | ssh | disable | install | cron
#
# Политики TTL: lock | locksudo | delete
# =====================================================
set -uo pipefail

VERSION="1.5.1"
CONF_DIR="/etc/openvibessh"
LIST_FILE="$CONF_DIR/agents.list"
AGENTS_CONF_DIR="$CONF_DIR/agents"
TTL_CONF="$CONF_DIR/ttl.conf"
LOG_FILE="/var/log/openvibessh.log"
SELF="/usr/local/bin/openvibessh.sh"
OVSSH_URL="https://raw.githubusercontent.com/artimm/openvibessh/main/openvibessh.sh"
DEFAULT_TTL="30"
DEFAULT_POLICY="lock"

info()  { echo -e "\033[0;34m[INFO]\033[0m $1"; }
ok()    { echo -e "\033[0;32m[ OK ]\033[0m $1"; }
warn()  { echo -e "\033[0;33m[ !!! ]\033[0m $1"; }
error() { echo -e "\033[0;31m[FAIL]\033[0m $1"; }

is_port_free() {
  if command -v ss >/dev/null 2>&1; then
    ! ss -tln 2>/dev/null | grep -qE "[:.]$1\b"
  else
    return 0
  fi
}

gen_password() { tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 14; }

validate_name() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; }

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    info "Требуются root-права — перезапускаю через sudo..."
    exec sudo bash "$0" "$@"
  fi
}

self_install() {
  if [ -f "$0" ] && [ "$(readlink -f "$0" 2>/dev/null)" != "$SELF" ]; then
    install -m 755 "$0" "$SELF" 2>/dev/null && ok "Скрипт установлен: $SELF"
  fi
}

load_ttl_defaults() { [ -f "$TTL_CONF" ] && source "$TTL_CONF" || true; }

# =====================================================
# Самоперезапуск из файла при pipe-запуске (curl ... | bash)
# =====================================================
if [ ! -t 0 ] && [ "${OVSSH_EXECED:-}" != "1" ]; then
  OVSSH_TMP="$(mktemp /tmp/ovssh.XXXXXX.sh 2>/dev/null || echo /tmp/ovssh.sh)"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$OVSSH_URL" -o "$OVSSH_TMP"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$OVSSH_TMP" "$OVSSH_URL"
  else
    cat > "$OVSSH_TMP"
  fi
  chmod +x "$OVSSH_TMP" 2>/dev/null
  export OVSSH_EXECED=1
  # stdin - труба от curl; переключаем на терминал, чтобы меню и вопросы работали
  if [ -e /dev/tty ]; then
    exec bash "$OVSSH_TMP" "$@" < /dev/tty
  fi
  exec bash "$OVSSH_TMP" "$@"
fi

# =====================================================
# SSH: установить / включить / запустить
# =====================================================
ensure_sshd() {
  echo "=== SSH: проверка установки и запуска ==="
  if ! command -v sshd >/dev/null 2>&1 && [ ! -x /usr/sbin/sshd ]; then
    info "openssh-server не установлен — устанавливаю..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq 2>/dev/null
    if apt-get install -y -qq openssh-server 2>/dev/null; then
      ok "openssh-server установлен."
    else
      error "Не удалось установить openssh-server."
      return 1
    fi
  else
    ok "openssh-server уже установлен."
  fi

  mkdir -p /etc/ssh/sshd_config.d
  printf 'PasswordAuthentication yes\nPort 22\n' > /etc/ssh/sshd_config.d/60-openvibessh.conf

  if systemctl list-unit-files ssh.socket >/dev/null 2>&1 && systemctl is-enabled ssh.socket >/dev/null 2>&1; then
    info "Обнаружен ssh.socket (socket-activation) — отключаю..."
    systemctl stop ssh.socket 2>/dev/null
    systemctl disable ssh.socket 2>/dev/null
  fi

  if systemctl is-enabled ssh >/dev/null 2>&1; then
    ok "Служба ssh в автозапуске."
  else
    info "Служба ssh выключена — включаю..."
    systemctl enable ssh 2>/dev/null && ok "Служба ssh включена."
  fi

  local st
  st=$(systemctl is-active ssh 2>/dev/null)
  if [ "$st" = "active" ]; then
    systemctl restart ssh && ok "ssh перезапущен (конфиг применен)."
  else
    info "Служба ssh не запущена (${st:-unknown}) — запускаю..."
    systemctl start ssh && ok "ssh запущен."
  fi

  sleep 1
  if ss -tln 2>/dev/null | grep -qE '[:.]22\b'; then
    ok "Порт 22 слушается."
  else
    warn "Порт 22 не слушается — смотрите: journalctl -u ssh -n 20"
  fi
}

# =====================================================
# TTL: планировщик
# =====================================================
install_timer() {
  need_root "$@"
  self_install
  if [ ! -f "$SELF" ]; then
    warn "Не удалось установить скрипт в $SELF — таймер не поставлен."
    return 1
  fi
  cat > /etc/systemd/system/openvibessh-cron.service <<EOF
[Unit]
Description=openvibessh TTL scheduler (auto-disable idle agents)

[Service]
Type=oneshot
ExecStart=$SELF cron
EOF
  cat > /etc/systemd/system/openvibessh-cron.timer <<EOF
[Unit]
Description=Run openvibessh TTL check every 2 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now openvibessh-cron.timer 2>/dev/null
  ok "Планировщик активен: проверка простоя каждые 2 минуты."
}

get_last_activity_epoch() {
  local ll e=""
  ll=$(lastlog -u "$1" 2>/dev/null | tail -n +2 | sed 's/.*Latest login: //' | xargs)
  if [ -n "$ll" ] && [[ "$ll" != Never* ]]; then
    e=$(date -d "$ll" +%s 2>/dev/null)
  fi
  local created="${2:-0}"
  if [ -n "$e" ] && [ "$e" -gt "$created" ]; then
    echo "$e"
  else
    echo "$created"
  fi
}

apply_policy() {
  local n="$1" pol="$2" sudo_mode="$3"
  case "$pol" in
    lock)
      passwd -l "$n" >/dev/null 2>&1
      usermod -L "$n" >/dev/null 2>&1
      [ -f /etc/sudoers.d/91-ovssh-"$n" ] && mv /etc/sudoers.d/91-ovssh-"$n" /etc/sudoers.d/91-ovssh-"$n".disabled
      pkill -u "$n" >/dev/null 2>&1 || true
      ;;
    locksudo)
      [ -f /etc/sudoers.d/91-ovssh-"$n" ] && mv /etc/sudoers.d/91-ovssh-"$n" /etc/sudoers.d/91-ovssh-"$n".disabled
      ;;
    delete)
      pkill -u "$n" >/dev/null 2>&1 || true
      userdel "$n" >/dev/null 2>&1 || true
      mkdir -p /home/opencode/archive
      local home_dir
      home_dir=$(getent passwd "$n" 2>/dev/null | cut -d: -f6)
      if [ -n "$home_dir" ] && [ -d "$home_dir" ]; then
        mv "$home_dir" "/home/opencode/archive/${n}_$(date +%Y%m%d-%H%M%S)" 2>/dev/null
      fi
      ;;
  esac
}

cron_mode() {
  need_root "$@"
  load_ttl_defaults
  [ -f "$LIST_FILE" ] || exit 0
  local now
  now=$(date +%s)
  local name sudo_mode ttl pol state created last idle out
  while IFS='|' read -r name f2 f3 f4 f5 f6; do
    [ -n "$name" ] || continue
    sudo_mode=$(echo "$f2" | sed 's/sudo=//')
    ttl=$(echo "$f4" | sed 's/ttl=//')
    pol=$(echo "$f5" | sed 's/policy=//')
    state=$(echo "$f6" | sed 's/state=//')
    ttl="${ttl:-$DEFAULT_TTL}"
    pol="${pol:-$DEFAULT_POLICY}"
    [ "$state" = "ACTIVE" ] || continue
    created=0
    [ -f "$AGENTS_CONF_DIR/$name.conf" ] && source "$AGENTS_CONF_DIR/$name.conf"
    last=$(get_last_activity_epoch "$name" "$created")
    idle=$(( (now - last) / 60 ))
    if [ "$idle" -ge "$ttl" ]; then
      apply_policy "$name" "$pol" "$sudo_mode"
      out=""
      while IFS= read -r line; do
        if [[ "$line" == "$name|"* ]]; then
          out+="${line%state=*}state=DISABLED"$'\n'
        else
          out+="$line"$'\n'
        fi
      done < "$LIST_FILE"
      printf '%s' "$out" > "$LIST_FILE"
      echo "$(date '+%Y-%m-%d %H:%M:%S') agent=$name policy=$pol idle=${idle}m ttl=${ttl}m -> DISABLED" >> "$LOG_FILE"
      warn "Агент '$name' отключен (простой ${idle}м >= ${ttl}м, политика: $pol)."
    fi
  done < "$LIST_FILE"
}

ttl_mode() {
  need_root "$@"
  local ttl="${1:-}" pol="${2:-}"
  if ! [[ "$ttl" =~ ^[0-9]+$ ]] || [ "$ttl" -lt 1 ]; then
    error "Укажите минуты: $0 ttl 30 lock"
    exit 1
  fi
  pol="${pol:-lock}"
  case "$pol" in lock|locksudo|delete) ;; *) error "Политика: lock | locksudo | delete"; exit 1 ;; esac
  mkdir -p "$CONF_DIR"
  echo "DEFAULT_TTL=$ttl" > "$TTL_CONF"
  echo "DEFAULT_POLICY=$pol" >> "$TTL_CONF"
  ok "По умолчанию: автоотключение через $ttl мин простоя, политика: $pol"
  install_timer
}

# =====================================================
# КОНТЕЙНЕР: создание агента (неинтерактивно — для вызова с хоста)
# =====================================================
agent_add_batch() {
  need_root "$@"
  local NAME="${1:-}" PASS="${2:-}" TTL="${3:-}" POLICY="${4:-}" SUDO_MODE="${5:-no}"
  load_ttl_defaults
  TTL="${TTL:-$DEFAULT_TTL}"
  POLICY="${POLICY:-$DEFAULT_POLICY}"
  validate_name "$NAME" || { error "Недопустимое имя: $NAME"; exit 1; }
  [ "$PASS" = "-" ] && PASS=$(gen_password)
  [[ "$TTL" =~ ^[0-9]+$ ]] && [ "$TTL" -ge 1 ] || TTL="$DEFAULT_TTL"
  case "$POLICY" in lock|locksudo|delete) ;; *) POLICY="$DEFAULT_POLICY" ;; esac
  case "$SUDO_MODE" in no|askpass|nopasswd) ;; *) SUDO_MODE="no" ;; esac

  if id -u "$NAME" >/dev/null 2>&1; then
    passwd -u "$NAME" >/dev/null 2>&1
    chage -E -1 "$NAME" >/dev/null 2>&1
  else
    useradd -m -s /bin/bash "$NAME" || { error "useradd failed"; exit 1; }
  fi
  echo "$NAME:$PASS" | chpasswd

  if [ "$SUDO_MODE" = "nopasswd" ]; then
    mkdir -p /etc/sudoers.d
    echo "$NAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/91-ovssh-"$NAME"
    chmod 440 /etc/sudoers.d/91-ovssh-"$NAME"
    usermod -aG sudo "$NAME" 2>/dev/null
  elif [ "$SUDO_MODE" = "askpass" ]; then
    usermod -aG sudo "$NAME" 2>/dev/null
  else
    rm -f /etc/sudoers.d/91-ovssh-"$NAME" 2>/dev/null
  fi

  ensure_sshd

  mkdir -p "$CONF_DIR" "$AGENTS_CONF_DIR"
  [ -f "$AGENTS_CONF_DIR/$NAME.conf" ] || echo "CREATED_EPOCH=$(date +%s)" > "$AGENTS_CONF_DIR/$NAME.conf"
  touch "$LIST_FILE"
  grep -v "^$NAME|" "$LIST_FILE" > "$LIST_FILE.tmp" 2>/dev/null || true
  mv "$LIST_FILE.tmp" "$LIST_FILE" 2>/dev/null
  echo "$NAME|sudo=$SUDO_MODE|$(date +%Y-%m-%d)|ttl=$TTL|policy=$POLICY|state=ACTIVE" >> "$LIST_FILE"

  self_install
  if [ ! -f /etc/systemd/system/openvibessh-cron.timer ]; then
    install_timer
  fi

  echo "OVSSH_AGENT_OK=$NAME"
  echo "OVSSH_AGENT_PASS=$PASS"
  echo "OVSSH_AGENT_TTL=$TTL"
  echo "OVSSH_AGENT_POLICY=$POLICY"
  echo "OVSSH_AGENT_SUDO=$SUDO_MODE"
}

# =====================================================
# КОНТЕЙНЕР: интерактивная выдача доступа
# =====================================================
agent_mode() {
  need_root "$@"
  local NAME="${1:-}"
  if [ -z "$NAME" ]; then
    read -rp "Имя агента (логин): " NAME
  fi
  shift || true
  local TTL="${1:-}"
  shift || true
  local POLICY="${1:-}"
  load_ttl_defaults
  TTL="${TTL:-$DEFAULT_TTL}"
  POLICY="${POLICY:-$DEFAULT_POLICY}"

  validate_name "$NAME" || { error "Недопустимое имя: строчные a-z, цифры, '-', '_'."; exit 1; }
  [[ "$TTL" =~ ^[0-9]+$ ]] && [ "$TTL" -ge 1 ] || { error "TTL должен быть числом минут."; exit 1; }
  case "$POLICY" in lock|locksudo|delete) ;; *) error "Политика: lock | locksudo | delete"; exit 1 ;; esac

  local SUDO_MODE="no"
  read -rp "Дать sudo БЕЗ пароля (NOPASSWD)? (y/N): " sn
  if [[ "${sn:-}" =~ ^[Yy]$ ]]; then SUDO_MODE="nopasswd"; else
    read -rp "Добавить в группу sudo (sudo будет спрашивать пароль)? (y/N): " sg
    [[ "${sg:-}" =~ ^[Yy]$ ]] && SUDO_MODE="askpass"
  fi

  local PASS=""
  read -rp "Пароль (Enter — сгенерировать случайный): " p
  if [ -n "${p:-}" ]; then PASS="$p"; else PASS=$(gen_password); fi

  agent_add_batch "$NAME" "$PASS" "$TTL" "$POLICY" "$SUDO_MODE"

  local CIP
  CIP=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo ""
  ok "============================================="
  ok "Агент '$NAME' готов!"
  echo "  Логин:    $NAME"
  echo "  Пароль:   $PASS"
  echo "  Sudo:     $SUDO_MODE"
  echo "  TTL:      $TTL мин простоя (политика: $POLICY)"
  echo "  Внутри:   ssh $NAME@${CIP:-<IP_контейнера>} (порт 22)"
  ok "============================================="
}

# =====================================================
# КОНТЕЙНЕР: список + отключение
# =====================================================
list_mode() {
  need_root "$@"
  load_ttl_defaults
  echo "=== Выданные доступы ($LIST_FILE) ==="
  if [ -f "$LIST_FILE" ] && [ -s "$LIST_FILE" ]; then
    printf "%-16s %-10s %-8s %-9s %-9s %-12s\n" "АГЕНТ" "SUDO" "TTL" "ПОЛИТИКА" "СТАТУС" "ОСТАЛОСЬ"
    local now
    now=$(date +%s)
    while IFS='|' read -r name f2 f3 f4 f5 f6; do
      [ -n "$name" ] || continue
      local sudo_mode ttl pol state rem
      sudo_mode=$(echo "$f2" | sed 's/sudo=//')
      ttl=$(echo "$f4" | sed 's/ttl=//'); ttl="${ttl:-$DEFAULT_TTL}"
      pol=$(echo "$f5" | sed 's/policy=//'); pol="${pol:-$DEFAULT_POLICY}"
      state=$(echo "$f6" | sed 's/state=//')
      rem="-"
      if [ "$state" = "ACTIVE" ]; then
        local created=0 last=0 idle=0
        [ -f "$AGENTS_CONF_DIR/$name.conf" ] && source "$AGENTS_CONF_DIR/$name.conf"
        last=$(get_last_activity_epoch "$name" "$created")
        idle=$(( (now - last) / 60 ))
        rem=$(( ttl - idle ))
        [ "$rem" -lt 0 ] && rem=0
        rem="${rem} мин"
      fi
      printf "%-16s %-10s %-8s %-9s %-9s %-12s\n" "$name" "$sudo_mode" "${ttl}м" "$pol" "$state" "$rem"
    done < "$LIST_FILE"
  else
    warn "Записей нет — доступы еще не выдавались."
  fi
  echo ""
  echo "=== Журнал автоотключений ($LOG_FILE) ==="
  [ -f "$LOG_FILE" ] && tail -5 "$LOG_FILE" || echo "  (пусто)"
}

disable_now() {
  need_root "$@"
  local NAME="${1:-}"
  [ -z "$NAME" ] && { error "Укажите имя: $0 disable <имя>"; exit 1; }
  local sudo_mode
  sudo_mode=$(grep "^$NAME|" "$LIST_FILE" 2>/dev/null | head -1 | grep -oE 'sudo=[a-z]+' | sed 's/sudo=//')
  [ -n "$sudo_mode" ] || sudo_mode="no"
  apply_policy "$NAME" "lock" "$sudo_mode"
  grep -v "^$NAME|" "$LIST_FILE" > "$LIST_FILE.tmp" 2>/dev/null || true
  mv "$LIST_FILE.tmp" "$LIST_FILE" 2>/dev/null
  ok "Агент '$NAME' отключен и убран из списка."
}

# =====================================================
# ХОСТ: выбор контейнера
# =====================================================
pick_container() {
  local CT="$1"
  mapfile -t CTRS < <(lxc list --format csv -c ns 2>/dev/null | awk -F, '$2=="RUNNING"{print $1}')
  if [ "${#CTRS[@]}" -eq 0 ]; then
    error "Нет запущенных LXD-контейнеров."
    return 1
  fi
  if [ -z "$CT" ]; then
    echo "Активные контейнеры:"
    local i=1
    for c in "${CTRS[@]}"; do echo "  $i) $c"; i=$((i+1)); done
    read -rp "Номер контейнера [1-$((i-1))]: " n
    if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt $((i-1)) ]; then
      error "Неверный выбор."; return 1
    fi
    CT="${CTRS[$((n-1))]}"
  else
    local found=false
    for c in "${CTRS[@]}"; do [ "$c" = "$CT" ] && found=true; done
    $found || { error "Контейнер '$CT' не найден среди запущенных."; return 1; }
  fi
  echo "$CT"
}

# =====================================================
# ХОСТ: открыть доступ (+ создать агента удаленно)
# =====================================================
open_access() {
  local CT="${1:-}" PORT="${2:-}"
  CT=$(pick_container "$CT") || return 1

  if [ -z "$PORT" ]; then
    read -rp "Внешний SSH-порт на хосте [2424]: " PORT
  fi
  PORT="${PORT:-2424}"
  if ! is_port_free "$PORT"; then
    error "Порт $PORT на хосте уже занят."
    return 1
  fi

  info "Контейнер: $CT | внешний порт: $PORT -> внутренний 22"

  info "Готовим SSH внутри контейнера..."
  if lxc exec "$CT" -- bash -c "command -v sshd >/dev/null 2>&1 || { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq 2>/dev/null; apt-get install -y -qq openssh-server 2>/dev/null; }; mkdir -p /etc/ssh/sshd_config.d; printf 'PasswordAuthentication yes\nPort 22\n' > /etc/ssh/sshd_config.d/60-openvibessh.conf; if systemctl list-unit-files ssh.socket >/dev/null 2>&1 && systemctl is-enabled ssh.socket >/dev/null 2>&1; then systemctl stop ssh.socket; systemctl disable ssh.socket 2>/dev/null; fi; systemctl enable ssh >/dev/null 2>&1; systemctl restart ssh"; then
    ok "SSH в контейнере готов (порт 22, пароли разрешены)."
  else
    warn "Не удалось подготовить SSH автоматически."
  fi

  lxc config device remove "$CT" "ovssh-$PORT" >/dev/null 2>&1 || true
  if lxc config device add "$CT" "ovssh-$PORT" proxy listen=tcp:0.0.0.0:$PORT connect=tcp:127.0.0.1:22; then
    ok "Проброс добавлен: хост:$PORT -> контейнер:22"
  else
    error "Не удалось добавить proxy-устройство LXD."
    return 1
  fi

  read -rp "Создать агента внутри контейнера сейчас? (Y/n): " ca
  if [[ ! "${ca:-}" =~ ^[Nn]$ ]]; then
    local NAME PASS TTL POLICY SUDO_MODE
    read -rp "Имя агента (логин): " NAME
    if ! validate_name "$NAME"; then error "Недопустимое имя."; return 1; fi
    read -rp "Пароль (Enter — сгенерировать случайный): " p
    if [ -n "${p:-}" ]; then PASS="$p"; else PASS=$(gen_password); fi
    read -rp "Минут простоя до автоотключения [30]: " TTL
    TTL="${TTL:-30}"
    read -rp "Политика (lock / locksudo / delete) [lock]: " POLICY
    POLICY="${POLICY:-lock}"
    read -rp "Sudo: nopasswd / askpass / no [nopasswd]: " SUDO_MODE
    SUDO_MODE="${SUDO_MODE:-nopasswd}"

    info "Создаю агента '$NAME' внутри контейнера..."
    if lxc exec "$CT" -- bash -c "command -v curl >/dev/null 2>&1 || { export DEBIAN_FRONTEND=noninteractive; apt-get update -qq 2>/dev/null; apt-get install -y -qq curl 2>/dev/null; }; curl -fsSL $OVSSH_URL -o /tmp/ovssh-agent.sh 2>/dev/null && bash /tmp/ovssh-agent.sh agent-add '$NAME' '$PASS' '$TTL' '$POLICY' '$SUDO_MODE'"; then
      local HIP
      HIP=$(hostname -I 2>/dev/null | awk '{print $1}')
      echo ""
      ok "============================================="
      ok "Полностью готово!"
      echo "  Подключение:  ssh $NAME@${HIP:-<IP_ХОСТА>} -p $PORT"
      echo "  Пароль:       указан выше при создании"
      echo "  TTL:          $TTL мин простоя (политика: $POLICY)"
      ok "============================================="
      return 0
    else
      error "Не удалось создать агента удаленно. Вручную:"
      echo "  lxc exec $CT -- bash -c \"curl -fsSL $OVSSH_URL | bash -s -- agent <имя>\""
      return 1
    fi
  fi
  return 0
}

# =====================================================
# ХОСТ: список и закрытие портов
# =====================================================
list_host_ports() {
  echo "=== Открытые SSH-порты (openvibessh) ==="
  local found=false
  while IFS= read -r ct; do
    [ -n "$ct" ] || continue
    while IFS= read -r dev; do
      [ -n "$dev" ] || continue
      local listen connect
      listen=$(lxc config device get "$ct" "$dev" listen 2>/dev/null | sed 's/tcp:0.0.0.0://')
      connect=$(lxc config device get "$ct" "$dev" connect 2>/dev/null | sed 's/tcp:127.0.0.1://')
      echo "  $ct: $listen -> $connect"
      found=true
    done < <(lxc config device list "$ct" 2>/dev/null | grep "ovssh-")
  done < <(lxc list --format csv -c n 2>/dev/null)
  $found || warn "Открытых портов openvibessh нет."
}

close_access() {
  local rows
  rows=$(lxc list --format csv -c n 2>/dev/null | while IFS= read -r ct; do
      [ -n "$ct" ] || continue
      while IFS= read -r dev; do
        [ -n "$dev" ] || continue
        local listen
        listen=$(lxc config device get "$ct" "$dev" listen 2>/dev/null | sed 's/tcp:0.0.0.0://')
        echo "$ct|$dev|$listen"
      done < <(lxc config device list "$ct" 2>/dev/null | grep "ovssh-")
  done)
  if [ -z "$rows" ]; then
    warn "Открытых портов openvibessh нет."
    return
  fi
  echo "Открытые порты:"
  local i=1
  local arr_ct=() arr_dev=() arr_l=()
  while IFS='|' read -r ct dev l; do
    echo "  $i) $ct: $l"
    arr_ct+=("$ct"); arr_dev+=("$dev"); arr_l+=("$l")
    i=$((i+1))
  done <<< "$rows"
  read -rp "Номер для закрытия [1-$((i-1))]: " n
  if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le $((i-1)) ]; then
    lxc config device remove "${arr_ct[$((n-1))]}" "${arr_dev[$((n-1))]}" \
      && ok "Доступ закрыт: ${arr_ct[$((n-1))]} порт ${arr_l[$((n-1))]}"
  else
    error "Неверный выбор."
  fi
}

host_menu() {
  while true; do
    echo ""
    echo "====================================================="
    echo "   OPENVIBESSH v$VERSION — режим LXD-хоста"
    echo "====================================================="
    echo " 1) Открыть доступ контейнеру (порт + агент)"
    echo " 2) Список открытых портов"
    echo " 3) Закрыть доступ (удалить порт)"
    echo " 0) Выход"
    echo "====================================================="
    read -rp "Выбор [0-3]: " c || exit 0
    case "${c:-}" in
      1) open_access ;;
      2) list_host_ports ;;
      3) close_access ;;
      0) exit 0 ;;
      *) warn "Неизвестный пункт." ;;
    esac
  done
}

# =====================================================
# КОНТЕЙНЕР: меню
# =====================================================
menu_container() {
  while true; do
    echo ""
    echo "====================================================="
    echo "   OPENVIBESSH v$VERSION — режим контейнера"
    echo "====================================================="
    echo " 1) Выдать доступ агенту (логин + пароль + sudo + TTL)"
    echo " 2) Список доступов и остаток времени"
    echo " 3) Настроить TTL автоотключения"
    echo " 4) Починить SSH (установить / включить / перезапустить)"
    echo " 5) Отключить агента немедленно"
    echo " 6) Установить скрипт в систему (команда ovssh)"
    echo " 0) Выход"
    echo "====================================================="
    read -rp "Выбор [0-6]: " c || exit 0
    case "${c:-}" in
      1) agent_mode "" ;;
      2) list_mode ;;
      3) read -rp "Минут простоя до отключения [30]: " m
       read -rp "Политика (lock / locksudo / delete) [lock]: " p
       ttl_mode "${m:-30}" "${p:-lock}" ;;
      4) ensure_sshd ;;
      5) read -rp "Имя агента: " n
       [ -n "$n" ] && disable_now "$n" ;;
      6) install_mode ;;
      0) exit 0 ;;
      *) warn "Неизвестный пункт." ;;
    esac
  done
}

install_mode() {
  need_root "$@"
  self_install
  ln -sf "$SELF" /usr/local/bin/ovssh
  ok "============================================="
  ok "openvibessh установлен в систему!"
  echo "  Команды:  ovssh          (меню/автоопределение)"
  echo "            ovssh host     (на LXD-хосте)"
  echo "            ovssh agent <имя> [минут] [политика]"
  echo "            ovssh list | ssh | disable <имя> | ttl <минут>"
  ok "============================================="
}

# =====================================================
usage() {
  echo "OPENVIBESSH v$VERSION — выдача SSH-доступа агентам в LXD (+TTL планировщик)"
  echo "  $0                     — меню (хост или контейнер, автоопределение)"
  echo "  $0 open [CT] [порт]    — на хосте: открыть доступ контейнеру"
  echo "  $0 ports               — на хосте: список открытых портов"
  echo "  $0 close               — на хосте: закрыть доступ"
  echo "  $0 agent <имя> [минут] [политика]          — в контейнере"
  echo "  $0 agent-add <имя> <пароль|-> <минуты> <политика> <no|askpass|nopasswd>"
  echo "  $0 list | disable <имя> | ssh | ttl <минут> [политика]"
  echo "  $0 install             — прописать скрипт в систему (команда ovssh)"
  echo ""
  echo "Политики TTL: lock (блок всего), locksudo (только sudo), delete (полный отзыв)"
}

main() {
  case "${1:-}" in
    host)      host_menu ;;
    open)      shift; open_access "$@" ;;
    ports)     list_host_ports ;;
    close)     close_access ;;
    agent)     shift; agent_mode "$@" ;;
    agent-add) shift; agent_add_batch "$@" ;;
    ttl)       shift; ttl_mode "$@" ;;
    list)      list_mode ;;
    disable)   shift; disable_now "$@" ;;
    ssh)       ensure_sshd ;;
    install)   install_mode ;;
    cron)      cron_mode ;;
    -h|--help|help) usage ;;
    "")
      if command -v lxc >/dev/null 2>&1; then
        host_menu
      else
        menu_container
      fi ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
