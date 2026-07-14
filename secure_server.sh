#!/bin/bash
#
# secure_server_setup.sh
# Совместим с: Ubuntu 20.04 / 22.04 / 24.04 / 26.04, Debian 10-13
#
set -uo pipefail
# ВНИМАНИЕ: set -e сознательно НЕ используется глобально — отдельные команды
# (sysctl -p, apt, modprobe) могут возвращать ненулевой код на некоторых
# системах (например, если модуль ядра conntrack не загружен), и раньше это
# аварийно останавливало весь скрипт. Критичные проверки делаются явно через if/||.

LOG_FILE="/var/log/secure_server_setup.log"
CREDS_FILE="/root/server_setup_credentials.txt"

log()     { echo -e "\e[34m[INFO]\e[0m $1" | tee -a "$LOG_FILE"; }
success() { echo -e "\e[32m[SUCCESS]\e[0m $1" | tee -a "$LOG_FILE"; }
error()   { echo -e "\e[31m[ERROR]\e[0m $1" | tee -a "$LOG_FILE"; }
warn()    { echo -e "\e[33m[WARN]\e[0m $1" | tee -a "$LOG_FILE"; }

ask() {
    # Читаем из /dev/tty, чтобы работать и при запуске через curl | bash
    local ans
    read -rp "$1 (y/n): " ans < /dev/tty
    [[ "$ans" == "y" || "$ans" == "Y" ]]
}

backup() {
    local file=$1
    [ -f "$file" ] && cp "$file" "$file.bak.$(date +%s)"
}

safe_sysctl_apply() {
    # sysctl -p падает целиком, если хотя бы один ключ недоступен
    # (например net.netfilter.nf_conntrack_max без загруженного модуля conntrack).
    # Применяем построчно и не роняем скрипт на отдельных ошибках.
    local file=$1
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "$line" ]] && continue
        sysctl -w "${line// = /=}" >/dev/null 2>>"$LOG_FILE" || warn "Не удалось применить: $line"
    done < "$file"
}

if [ "$EUID" -ne 0 ]; then
    error "Запустите скрипт от root"
    exit 1
fi

echo "==== Secure Server Setup ====" | tee -a "$LOG_FILE"

################################################
# 0. ОПРЕДЕЛЕНИЕ ДИСТРИБУТИВА
################################################

if [ ! -f /etc/os-release ]; then
    error "Не удалось определить дистрибутив (/etc/os-release отсутствует)"
    exit 1
fi

# shellcheck source=/dev/null
. /etc/os-release
OS_ID="${ID:-unknown}"
OS_VERSION="${VERSION_ID:-unknown}"

case "$OS_ID" in
    ubuntu)
        case "$OS_VERSION" in
            20.04|22.04|24.04|26.04) ;;
            *) warn "Ubuntu $OS_VERSION официально не тестировался, но должен подойти (apt-based)." ;;
        esac
        ;;
    debian)
        case "$OS_VERSION" in
            10|11|12|13) ;;
            *) warn "Debian $OS_VERSION официально не тестировался, но должен подойти (apt-based)." ;;
        esac
        ;;
    *)
        error "Поддерживаются только Ubuntu и Debian. Обнаружено: $OS_ID $OS_VERSION"
        exit 1
        ;;
esac

log "Обнаружена система: $PRETTY_NAME"

if [ -z "${SSH_CLIENT:-}${SSH_TTY:-}" ]; then
    warn "Похоже, вы не в SSH-сессии. Если работаете в консоли провайдера — ок,
но если это единственный доступ к серверу, будьте внимательны при смене SSH-порта/пароля."
fi

################################################
# 1. ОБНОВЛЕНИЕ СИСТЕМЫ
################################################

if ask "1) Обновить систему?"; then
    log "Обновляем систему"
    apt update && apt upgrade -y
    success "Система обновлена"
fi

################################################
# 2. БАЗОВЫЕ ПАКЕТЫ (nginx — отдельным флагом, т.к. от него зависят другие шаги)
################################################

BASE_PACKAGES="nano htop net-tools unzip ufw fail2ban unattended-upgrades curl"
INSTALL_NGINX="no"

echo "Будут установлены пакеты: $BASE_PACKAGES"

if ask "2) Установить базовые пакеты?"; then
    log "Установка базовых пакетов"
    apt install -y $BASE_PACKAGES
    success "Пакеты установлены"
fi

if ask "2а) Установить nginx?"; then
    apt install -y nginx
    INSTALL_NGINX="yes"
    success "nginx установлен"
else
    log "nginx не устанавливается — связанные с ним шаги (заглушка, скрытие версии) будут пропущены"
fi

################################################
# 3. ТАЙМЗОНА
################################################

if ask "3) Установить таймзону?"; then
    timedatectl
    read -rp "Введите таймзону (например Europe/Vienna): " TZ_INPUT < /dev/tty
    if timedatectl set-timezone "$TZ_INPUT" 2>>"$LOG_FILE"; then
        success "Таймзона установлена: $TZ_INPUT"
    else
        error "Некорректная таймзона: $TZ_INPUT"
    fi
fi

################################################
# 4. СОЗДАНИЕ НОВОГО ПОЛЬЗОВАТЕЛЯ
################################################

NEWUSER=""
USER_PASSWORD=""

if ask "4) Создать нового пользователя?"; then
    read -rp "Имя пользователя: " NEWUSER < /dev/tty
    if id "$NEWUSER" &>/dev/null; then
        error "Пользователь уже существует"
        NEWUSER=""
    else
        USER_PASSWORD=$(openssl rand -base64 12)
        useradd -m -s /bin/bash "$NEWUSER"
        echo "$NEWUSER:$USER_PASSWORD" | chpasswd
        usermod -aG sudo "$NEWUSER"
        success "Пользователь создан: $NEWUSER"
    fi
fi

################################################
# 5. ПАРОЛЬ ROOT
################################################

ROOT_PASS=""

if ask "5) Сменить пароль root?"; then
    ROOT_PASS=$(openssl rand -base64 12)
    echo "root:$ROOT_PASS" | chpasswd
    success "Пароль root изменён"
fi

################################################
# 6. SSH — единый блок настроек, один restart в конце
################################################

SSH_CONFIG="/etc/ssh/sshd_config"
SSH_PORT=""
DISABLE_ROOT_SSH="no"
SSH_CHANGED="no"

if ask "6) Настроить SSH (root-логин / порт / лимиты / баннер)?"; then

    backup "$SSH_CONFIG"

    if ask "6.1) Запретить вход root по SSH?"; then
        if grep -q "^PermitRootLogin" "$SSH_CONFIG"; then
            sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' "$SSH_CONFIG"
        else
            echo "PermitRootLogin no" >> "$SSH_CONFIG"
        fi
        DISABLE_ROOT_SSH="yes"
        SSH_CHANGED="yes"
        success "Root SSH login отключён"
        if [ -z "$NEWUSER" ]; then
            warn "Вы отключаете root-логин, но новый sudo-пользователь не был создан на шаге 4! Убедитесь, что есть другой способ входа."
        fi
    fi

    if ask "6.2) Сменить SSH порт?"; then
        read -rp "Введите новый порт: " SSH_PORT < /dev/tty
        if grep -Eq "^#?Port " "$SSH_CONFIG"; then
            sed -i -E "s/^#?Port .*/Port $SSH_PORT/" "$SSH_CONFIG"
        else
            echo "Port $SSH_PORT" >> "$SSH_CONFIG"
        fi
        SSH_CHANGED="yes"
        success "SSH порт изменён на $SSH_PORT (не забудьте открыть его в firewall на следующем шаге)"
    fi

    if ask "6.3) Ограничить попытки входа (MaxAuthTries/LoginGraceTime)?"; then
        grep -q "^MaxAuthTries" "$SSH_CONFIG" || echo "MaxAuthTries 3" >> "$SSH_CONFIG"
        grep -q "^LoginGraceTime" "$SSH_CONFIG" || echo "LoginGraceTime 30" >> "$SSH_CONFIG"
        SSH_CHANGED="yes"
        success "SSH лимиты установлены"
    fi

    if ask "6.4) Убрать 'Debian' из баннера SSH? (примечание: версия OpenSSH всё равно останется видна в баннере)"; then
        grep -q "^DebianBanner" "$SSH_CONFIG" || echo "DebianBanner no" >> "$SSH_CONFIG"
        SSH_CHANGED="yes"
        success "Баннер скорректирован"
    fi

    if [ "$SSH_CHANGED" = "yes" ]; then
        if sshd -t 2>>"$LOG_FILE"; then
            systemctl restart ssh
            success "SSH перезапущен с новой конфигурацией"
        else
            error "Ошибка в конфигурации sshd_config — конфиг НЕ применён, проверьте $SSH_CONFIG вручную (бэкап рядом)"
        fi
    fi
fi

################################################
# 7. FIREWALL (учитывает реальный SSH-порт и nginx)
################################################

if ask "7) Настроить UFW firewall?"; then

    if [ -n "$SSH_PORT" ]; then
        ufw allow "$SSH_PORT"/tcp
        if ask "7.1) Также оставить открытым стандартный порт 22/tcp?"; then
            ufw allow 22/tcp
        fi
    else
        ufw allow 22/tcp
    fi

    if [ "$INSTALL_NGINX" = "yes" ]; then
        ufw allow 80/tcp
        ufw allow 443/tcp
    fi

    read -rp "Дополнительные порты через пробел (Enter — пропустить): " PORTS < /dev/tty
    for p in $PORTS; do
        ufw allow "$p"
    done

    ufw --force enable
    success "Firewall включён"
fi

################################################
# 8. FAIL2BAN (базовая защита SSH из коробки, но проверим, что сервис жив)
################################################

if command -v fail2ban-client &>/dev/null; then
    if ask "8) Включить и запустить fail2ban?"; then
        systemctl enable --now fail2ban
        success "fail2ban включён"
    fi
fi

################################################
# 9. СЕТЕВАЯ TCP-ОПТИМИЗАЦИЯ (только безопасные для сервера параметры)
################################################

SYSCTL="/etc/sysctl.conf"

if ask "9) Оптимизация TCP сети (BBR, буферы, backlog)?"; then

    backup "$SYSCTL"

    # Загружаем модуль BBR перед применением, иначе congestion_control не встанет
    modprobe tcp_bbr 2>>"$LOG_FILE" || warn "Модуль tcp_bbr не загрузился (возможно, уже встроен в ядро)"

    grep -q "default_qdisc = fq" "$SYSCTL" || echo "net.core.default_qdisc = fq" >> "$SYSCTL"
    grep -q "tcp_congestion_control = bbr" "$SYSCTL" || echo "net.ipv4.tcp_congestion_control = bbr" >> "$SYSCTL"
    grep -q "rmem_max" "$SYSCTL" || echo "net.core.rmem_max = 16777216" >> "$SYSCTL"
    grep -q "wmem_max" "$SYSCTL" || echo "net.core.wmem_max = 16777216" >> "$SYSCTL"
    grep -q "tcp_rmem" "$SYSCTL" || echo "net.ipv4.tcp_rmem = 4096 87380 16777216" >> "$SYSCTL"
    grep -q "tcp_wmem" "$SYSCTL" || echo "net.ipv4.tcp_wmem = 4096 65536 16777216" >> "$SYSCTL"
    grep -q "tcp_mtu_probing" "$SYSCTL" || echo "net.ipv4.tcp_mtu_probing = 1" >> "$SYSCTL"
    grep -q "netdev_max_backlog" "$SYSCTL" || echo "net.core.netdev_max_backlog = 250000" >> "$SYSCTL"
    grep -q "tcp_slow_start_after_idle" "$SYSCTL" || echo "net.ipv4.tcp_slow_start_after_idle = 0" >> "$SYSCTL"
    grep -q "tcp_tw_reuse" "$SYSCTL" || echo "net.ipv4.tcp_tw_reuse = 1" >> "$SYSCTL"
    grep -q "tcp_max_syn_backlog" "$SYSCTL" || echo "net.ipv4.tcp_max_syn_backlog = 8192" >> "$SYSCTL"
    grep -q "somaxconn" "$SYSCTL" || echo "net.core.somaxconn = 65535" >> "$SYSCTL"

    safe_sysctl_apply "$SYSCTL"
    success "TCP оптимизация применена"
fi

################################################
# 9а. МАРШРУТИЗАЦИЯ / IP FORWARDING — отдельно и с явным предупреждением
################################################
# Раньше эти параметры были смешаны с "TCP оптимизацией", хотя это НЕ про
# производительность, а про включение маршрутизации/приёма пакетов с
# нестандартных путей. На обычном сервере (не роутере/не VPN-шлюзе) их лучше
# не включать вовсе.

warn "Следующий пункт включает IP forwarding и приём 'локальных' пакетов на внешних интерфейсах."
warn "Нужно ТОЛЬКО если сервер работает как роутер / VPN-шлюз / NAT. Для обычного веб-сервера — не нужно."

if ask "9а) Включить IP forwarding и связанные параметры (только для роутера/VPN)?"; then
    backup "$SYSCTL"
    grep -q "^net.ipv4.ip_forward" "$SYSCTL" || echo "net.ipv4.ip_forward = 1" >> "$SYSCTL"
    safe_sysctl_apply "$SYSCTL"
    success "IP forwarding включён"
fi

################################################
# 10. SYN FLOOD ЗАЩИТА
################################################

if ask "10) Включить защиту от SYN flood (tcp_syncookies)?"; then
    backup "$SYSCTL"
    grep -q "tcp_syncookies" "$SYSCTL" || echo "net.ipv4.tcp_syncookies = 1" >> "$SYSCTL"
    safe_sysctl_apply "$SYSCTL"
    success "SYN flood защита включена"
fi

################################################
# 11. DNS
################################################

if ask "11) Настроить DNS?"; then
    read -rp "Введите DNS через пробел (например 1.1.1.1 8.8.8.8): " DNS < /dev/tty
    backup /etc/resolv.conf
    : > /etc/resolv.conf
    for d in $DNS; do
        echo "nameserver $d" >> /etc/resolv.conf
    done
    success "DNS настроен"
    warn "Если используется systemd-resolved/NetworkManager, изменения могут быть перезаписаны при перезагрузке."
fi

################################################
# 12. АВТООБНОВЛЕНИЯ БЕЗОПАСНОСТИ
################################################

if ask "12) Включить авто security-обновления?"; then
    if ! dpkg -l unattended-upgrades &>/dev/null; then
        apt install -y unattended-upgrades
    fi
    dpkg-reconfigure -plow unattended-upgrades
    success "Автообновления включены"
fi

################################################
# 13. NGINX-ЗАГЛУШКА (только если nginx реально установлен)
################################################

if [ "$INSTALL_NGINX" = "yes" ]; then

    if ask "13) Установить стартовую заглушку nginx?"; then
        mkdir -p /var/www/html
        cat > /var/www/html/index.html <<'EOF'
<html>
<head><title>Server</title></head>
<body>
<h1>Server is running</h1>
</body>
</html>
EOF
        if nginx -t 2>>"$LOG_FILE"; then
            systemctl restart nginx
            success "nginx работает, заглушка установлена"
        else
            error "Ошибка конфигурации nginx — заглушка создана, но nginx не перезапущен"
        fi
    fi

    if ask "14) Скрыть версию nginx (server_tokens off)?"; then
        backup /etc/nginx/nginx.conf
        grep -q "server_tokens off" /etc/nginx/nginx.conf || sed -i '/http {/a \    server_tokens off;' /etc/nginx/nginx.conf
        if nginx -t 2>>"$LOG_FILE"; then
            systemctl restart nginx
            success "Версия nginx скрыта"
        else
            error "Ошибка конфигурации nginx после правки — проверьте /etc/nginx/nginx.conf (бэкап рядом)"
        fi
    fi
else
    log "nginx не установлен — шаги 13-14 (заглушка / скрытие версии) пропущены"
fi

################################################
# 15. БЛОКИРОВКА PING
################################################

if ask "15) Заблокировать ICMP ping?"; then
    backup "$SYSCTL"
    grep -q "icmp_echo_ignore_all" "$SYSCTL" || echo "net.ipv4.icmp_echo_ignore_all = 1" >> "$SYSCTL"
    safe_sysctl_apply "$SYSCTL"
    log "Проверка (ping локального интерфейса тоже будет заблокирован — это ожидаемо):"
    ping -c 2 127.0.0.1 || log "Ping отключён"
fi

################################################
# ИТОГОВЫЕ ДАННЫЕ — сохраняем в защищённый файл, не светим в терминале
################################################

{
    echo "===== Secure Server Setup: учётные данные ====="
    echo "Дата: $(date)"
    [ -n "$NEWUSER" ] && echo "User: $NEWUSER"
    [ -n "$USER_PASSWORD" ] && echo "User password: $USER_PASSWORD"
    [ -n "$ROOT_PASS" ] && echo "Root password: $ROOT_PASS"
    [ -n "$SSH_PORT" ] && echo "SSH port: $SSH_PORT"
} > "$CREDS_FILE"
chmod 600 "$CREDS_FILE"

echo
echo "===== ДАННЫЕ ====="
echo "Учётные данные сохранены в $CREDS_FILE (права 600, только root)."
echo "Обязательно скопируйте их в менеджер паролей и удалите файл: shred -u $CREDS_FILE"
echo "=================="

################################################
# ПЕРЕЗАГРУЗКА
################################################

if ask "Перезагрузить сервер?"; then
    reboot
else
    success "Скрипт завершён. Лог: $LOG_FILE"
fi
