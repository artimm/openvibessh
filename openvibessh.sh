#!/usr/bin/env bash
# =====================================================
# OPENVIBESSH v1.0
# Выдача SSH-доступа агентам (логин + пароль + sudo) в LXD-контейнерах
#
# Режимы (определяются автоматически по наличию команды lxc):
#   ХОСТ:      ./openvibessh.sh host [контейнер] [внешний_порт]
#              — показывает активные контейнеры, готовит sshd в контейнере,
#                добавляет проброс: внешний порт хоста -> обычный 22 в контейнере
#   КОНТЕЙНЕР: ./openvibessh.sh agent <имя>
#              — создает агента: логин + пароль (без сертификатов), sudo по выбору
#              ./openvibessh.sh list
#              — список выданных доступов и эффективных прав (sudo -l)
# =====================================================
set -uo pipefail

VERSION="1.0"
LIST_FILE="/etc/openvibessh/agents.list"

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

# =====================================================
# РЕЖИМ ХОСТА: контейнеры + проброс порта
# =====================================================
host_mode() {
  command -v lxc >/dev/null 2>&1 || { error "Команда lxc не найдена — режим 'host' работает на LXD-хосте."; exit 1; }

  local CT="${1:-}"
  local PORT="${2:-}"

  mapfile -t CTRS < <(lxc list --format csv -c ns 2>/dev/null | awk -F, '$2=="RUNNING"{print $1}')
  if [ "${#CTRS[@]}" -eq 0 ]; then
    error "Нет запущенных LXD-контейнеров (lxc list пуст)."
    exit 1
  fi

  if [ -z "$CT" ]; then
    echo "Активные контейнеры:"
    local i=1
    for c in "${CTRS[@]}"; do echo "  $i) $c"; i=$((i+1)); done
    read -rp "Номер контейнера [1-$((i-1))]: " n
    if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt $((i-1)) ]; then
      error "Неверный выбор."; exit 1
    fi
    CT="${CTRS[$((n-1))]}"
  fi

  if [ -z "$PORT" ]; then
    read -rp "Внешний SSH-порт на хосте [2424]: " PORT
  fi
  PORT="${PORT:-2424}"
  if ! is_port_free "$PORT"; then
    error "Порт $PORT на хосте уже занят. Укажите другой."
    exit 1
  fi

  info "Контейнер: $CT | внешний порт: $PORT -> внутренний 22"

  info "Готовим SSH внутри контейнера (openssh-server + парольный вход)..."
  if lxc exec "$CT" -- bash -c "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq 2>/dev/null; apt-get install -y -qq openssh-server 2>/dev/null; mkdir -p /etc/ssh/sshd_config.d; printf 'PasswordAuthentication yes\nPort 22\n' > /etc/ssh/sshd_config.d/60-openvibessh.conf; if systemctl is-active ssh.socket >/dev/null 2>&1; then systemctl stop ssh.socket; systemctl disable ssh.socket 2>/dev/null; fi; systemctl enable ssh >/dev/null 2>&1; systemctl restart ssh"; then
    ok "SSH в контейнере готов (порт 22, вход по паролю разрешен)."
  else
    warn "Не удалось автоматически подготовить SSH — проверьте контейнер вручную."
  fi

  lxc config device remove "$CT" "ovssh-$PORT" >/dev/null 2>&1 || true
  if lxc config device add "$CT" "ovssh-$PORT" proxy listen=tcp:0.0.0.0:$PORT connect=tcp:127.0.0.1:22; then
    ok "Проброс добавлен: хост:$PORT -> контейнер:22"
  else
    error "Не удалось добавить proxy-устройство LXD."
    exit 1
  fi

  local HIP
  HIP=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo ""
  ok "Порт открыт. Следующий шаг — создать агента ВНУТРИ контейнера:"
  echo "  lxc exec $CT -- bash -c \"curl -fsSL https://raw.githubusercontent.com/artimm/openvibessh/main/openvibessh.sh | bash -s -- agent <имя>\""
  echo ""
  ok "Подключение агента:  ssh <имя>@${HIP:-<IP_ХОСТА>} -p $PORT"
}

# =====================================================
# РЕЖИМ КОНТЕЙНЕРА: выдача доступа агенту
# =====================================================
agent_mode() {
  need_root "$@"
  local NAME="${1:-}"
  if [ -z "$NAME" ]; then
    read -rp "Имя агента (логин): " NAME
  fi
  validate_name "$NAME" || { error "Недопустимое имя: строчные a-z, цифры, '-', '_'."; exit 1; }

  local SUDO_MODE="no"
  read -rp "Дать sudo БЕЗ пароля (NOPASSWD)? (y/N): " sn
  if [[ "${sn:-}" =~ ^[Yy]$ ]]; then SUDO_MODE="nopasswd"; else
    read -rp "Добавить в группу sudo (sudo будет спрашивать пароль)? (y/N): " sg
    [[ "${sg:-}" =~ ^[Yy]$ ]] && SUDO_MODE="askpass"
  fi

  local PASS=""
  read -rp "Пароль (Enter — сгенерировать случайный): " p
  if [ -n "${p:-}" ]; then PASS="$p"; else PASS=$(gen_password); fi

  if id -u "$NAME" >/dev/null 2>&1; then
    info "Пользователь '$NAME' уже существует — обновляю пароль и права."
  else
    useradd -m -s /bin/bash "$NAME" || { error "Не удалось создать пользователя."; exit 1; }
  fi
  echo "$NAME:$PASS" | chpasswd

  if [ "$SUDO_MODE" = "nopasswd" ]; then
    mkdir -p /etc/sudoers.d
    echo "$NAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/91-ovssh-"$NAME"
    chmod 440 /etc/sudoers.d/91-ovssh-"$NAME"
    usermod -aG sudo "$NAME" 2>/dev/null
  elif [ "$SUDO_MODE" = "askpass" ]; then
    usermod -aG sudo "$NAME" 2>/dev/null
    rm -f /etc/sudoers.d/91-ovssh-"$NAME" 2>/dev/null
  else
    rm -f /etc/sudoers.d/91-ovssh-"$NAME" 2>/dev/null
  fi

  if ! command -v sshd >/dev/null 2>&1; then
    info "Установка openssh-server..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq 2>/dev/null
    apt-get install -y -qq openssh-server 2>/dev/null
  fi
  mkdir -p /etc/ssh/sshd_config.d
  printf 'PasswordAuthentication yes\nPort 22\n' > /etc/ssh/sshd_config.d/60-openvibessh.conf
  if systemctl is-active ssh.socket >/dev/null 2>&1; then
    systemctl stop ssh.socket
    systemctl disable ssh.socket 2>/dev/null
  fi
  systemctl enable ssh >/dev/null 2>&1
  systemctl restart ssh

  mkdir -p /etc/openvibessh
  touch "$LIST_FILE"
  grep -v "^$NAME|" "$LIST_FILE" > "$LIST_FILE.tmp" 2>/dev/null || true
  mv "$LIST_FILE.tmp" "$LIST_FILE" 2>/dev/null
  echo "$NAME|sudo=$SUDO_MODE|$(date +%Y-%m-%d)" >> "$LIST_FILE"

  local CIP
  CIP=$(hostname -I 2>/dev/null | awk '{print $1}')
  echo ""
  ok "============================================="
  ok "Агент '$NAME' готов!"
  echo "  Логин:    $NAME"
  echo "  Пароль:   $PASS"
  echo "  Sudo:     $SUDO_MODE"
  echo "  Внутри:   ssh $NAME@${CIP:-<IP_контейнера>} (порт 22)"
  echo "  Снаружи:  ssh $NAME@<IP_хоста> -p <внешний порт>"
  echo "            (проброс настраивается режимом 'host' на LXD-хосте)"
  ok "============================================="
}

# =====================================================
# РЕЖИМ КОНТЕЙНЕРА: список выданных прав
# =====================================================
list_mode() {
  need_root "$@"
  echo "=== Выданные доступы ($LIST_FILE) ==="
  if [ -f "$LIST_FILE" ] && [ -s "$LIST_FILE" ]; then
    printf "%-16s %-12s %-12s\n" "АГЕНТ" "SUDO" "ДАТА"
    while IFS='|' read -r n s d; do
      printf "%-16s %-12s %-12s\n" "$n" "$s" "$d"
    done < "$LIST_FILE"
  else
    warn "Записей нет — доступы еще не выдавались."
  fi
  echo ""
  echo "=== Эффективные sudo-права ==="
  if [ -f "$LIST_FILE" ]; then
    while IFS='|' read -r n _ _; do
      echo "--- $n ---"
      sudo -l -U "$n" 2>/dev/null | sed -n '/may run/,$p' | head -4
    done < "$LIST_FILE"
  fi
  echo ""
  echo "=== Пользователи-агенты в системе ==="
  awk -F: '$3>=1000 && $3<60000 {print "  " $1 "  (home: " $6 ")"}' /etc/passwd
}

# =====================================================
usage() {
  echo "OPENVIBESSH v$VERSION — выдача SSH-доступа агентам в LXD"
  echo "  $0 host [контейнер] [порт]   — на хосте: контейнеры + проброс порта -> 22"
  echo "  $0 agent <имя>               — в контейнере: доступ (логин+пароль+sudo)"
  echo "  $0 list                      — в контейнере: список выданных прав"
}

main() {
  case "${1:-}" in
    host)  shift; host_mode "$@" ;;
    agent) shift; agent_mode "$@" ;;
    list)  list_mode ;;
    -h|--help|help) usage ;;
    "")
      if command -v lxc >/dev/null 2>&1; then
        host_mode
      else
        agent_mode ""
      fi ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
