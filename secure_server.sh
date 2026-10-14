#!/usr/bin/env bash
# Interactive initial hardening for Ubuntu and Debian.
set -uo pipefail

LOG_FILE=/var/log/secure_server_setup.log
CREDS_FILE=/root/server_setup_credentials.txt
SSH_CONFIG=/etc/ssh/sshd_config
SYSCTL_FILE=/etc/sysctl.d/99-secure-server-setup.conf
INSTALL_NGINX=no
NEWUSER=
USER_PASSWORD=
ROOT_PASS=
SSH_PORT=
SSH_CHANGED=no
SSH_RESTART_PENDING=no

mkdir -p "$(dirname "$LOG_FILE")" || exit 1
touch "$LOG_FILE" || { printf 'Cannot write log %s\n' "$LOG_FILE" >&2; exit 1; }
chmod 600 "$LOG_FILE" 2>/dev/null || true

log()     { printf '[INFO] %s\n' "$*" | tee -a "$LOG_FILE"; }
success() { printf '[SUCCESS] %s\n' "$*" | tee -a "$LOG_FILE"; }
warn()    { printf '[WARN] %s\n' "$*" | tee -a "$LOG_FILE"; }
error()   { printf '[ERROR] %s\n' "$*" | tee -a "$LOG_FILE" >&2; }

ask() {
    local answer
    while true; do
        if ! IFS= read -r -p "$1 (y/n): " answer </dev/tty; then
            warn 'Не удалось прочитать ответ из терминала; выбран ответ «нет».'
            return 1
        fi
        case "$answer" in y|Y|yes|YES|д|Д|да|ДА) return 0;; n|N|no|NO|н|Н|нет|НЕТ) return 1;; *) printf 'Введите y или n.\n';; esac
    done
}

prompt() {
    local __var=$1 __text=$2 __value
    IFS= read -r -p "$__text" __value </dev/tty || return 1
    printf -v "$__var" '%s' "$__value"
}

backup() {
    local file=$1
    if [[ -e "$file" ]]; then
        cp -a -- "$file" "$file.bak.$(date +%Y%m%d%H%M%S).$$" || return 1
    fi
}

run() {
    if "$@"; then return 0; else
        local rc=$?
        error "Команда завершилась с кодом $rc: $*"
        return "$rc"
    fi
}

valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }

set_sshd_value() {
    local key=$1 value=$2
    if grep -Eiq "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+" "$SSH_CONFIG"; then
        sed -i -E "s|^[[:space:]]*#?[[:space:]]*${key}[[:space:]]+.*|${key} ${value}|I" "$SSH_CONFIG"
    else
        printf '\n%s %s\n' "$key" "$value" >>"$SSH_CONFIG"
    fi
}

apply_sysctl() {
    local key=$1 value=$2 tmp
    tmp=$(mktemp) || return 1
    if [[ -f "$SYSCTL_FILE" ]]; then grep -Ev "^[[:space:]]*${key}[[:space:]]*=" "$SYSCTL_FILE" >"$tmp" || true; fi
    printf '%s = %s\n' "$key" "$value" >>"$tmp"
    install -m 644 "$tmp" "$SYSCTL_FILE" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    if sysctl -w "$key=$value" >/dev/null 2>>"$LOG_FILE"; then return 0; fi
    warn "Параметр сохранён, но пока не применён: $key=$value"
    return 1
}

if (( EUID != 0 )); then error 'Запустите скрипт от root'; exit 1; fi
if [[ ! -r /etc/os-release ]]; then error 'Не найден /etc/os-release'; exit 1; fi
# shellcheck source=/dev/null
. /etc/os-release
case "${ID:-}" in ubuntu|debian) ;; *) error "Поддерживаются Ubuntu и Debian; обнаружено: ${ID:-unknown}"; exit 1;; esac
if ! [[ -r /dev/tty && -w /dev/tty ]]; then error 'Нужен интерактивный терминал (/dev/tty).'; exit 1; fi

printf '\n==== Настройка сервера: %s ====\n' "${PRETTY_NAME:-$ID}"
printf 'Все пункты выполняются последовательно; отказ от пункта не прерывает остальные.\n'
if [[ -n "${SSH_CONNECTION:-}${SSH_CLIENT:-}" ]]; then
    warn 'Вы подключены по SSH. Не закрывайте текущую сессию, пока не проверите новое подключение.'
else
    warn 'SSH-сессия не обнаружена. Изменения SSH выполняйте только при наличии консоли провайдера.'
fi

printf '\n[1/15] Обновление системы\n'
if ask 'Обновить системные пакеты?'; then
    if apt-get update && DEBIAN_FRONTEND=noninteractive apt-get upgrade -y; then success 'Система обновлена'; else error 'Обновление завершилось с ошибкой'; fi
fi

printf '\n[2/15] Базовые пакеты\n'
if ask 'Установить базовые пакеты (nano, htop, net-tools, unzip, ufw, fail2ban, unattended-upgrades, curl, openssl)?'; then
    if apt-get install -y nano htop net-tools unzip ufw fail2ban unattended-upgrades curl openssl; then success 'Базовые пакеты установлены'; else error 'Не удалось установить базовые пакеты'; fi
fi
printf '\n[3/15] Nginx\n'
if ask 'Установить nginx?'; then
    if apt-get install -y nginx; then INSTALL_NGINX=yes; success 'nginx установлен'; else error 'nginx не установлен'; fi
fi

printf '\n[4/15] Часовой пояс\n'
if ask 'Изменить часовой пояс?'; then
    if command -v timedatectl >/dev/null 2>&1; then timedatectl; fi
    local_tz=
    if prompt local_tz 'Часовой пояс (например Europe/Vienna): ' && [[ -n "$local_tz" ]] && timedatectl set-timezone "$local_tz"; then success "Часовой пояс: $local_tz"; else error 'Не удалось изменить часовой пояс'; fi
fi

printf '\n[5/15] Администратор\n'
if ask 'Создать нового sudo-пользователя?'; then
    while true; do
        NEWUSER=
        if ! prompt NEWUSER 'Имя пользователя: ' || [[ ! "$NEWUSER" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]]; then error 'Недопустимое имя пользователя'; continue; fi
        if id "$NEWUSER" >/dev/null 2>&1; then error 'Пользователь уже существует'; continue; fi
        break
    done
    USER_PASSWORD=$(openssl rand -base64 18 | tr -d '\n')
    if useradd -m -s /bin/bash "$NEWUSER" && printf '%s:%s\n' "$NEWUSER" "$USER_PASSWORD" | chpasswd && usermod -aG sudo "$NEWUSER"; then
        success "Создан sudo-пользователь $NEWUSER"
    else error 'Создание пользователя не удалось; проверьте систему вручную'; NEWUSER=; USER_PASSWORD=; fi
fi

printf '\n[6/15] Пароль root\n'
if ask 'Сгенерировать и установить новый пароль root?'; then
    ROOT_PASS=$(openssl rand -base64 18 | tr -d '\n')
    if printf 'root:%s\n' "$ROOT_PASS" | chpasswd; then success 'Пароль root обновлён'; else error 'Не удалось изменить пароль root'; ROOT_PASS=; fi
fi

printf '\n[7/15] Подготовка SSH (применение будет после firewall)\n'
if ask 'Настроить SSH (root login, порт, лимиты, Debian banner)?'; then
    if [[ ! -f "$SSH_CONFIG" ]]; then error "Не найден $SSH_CONFIG"; else
        backup "$SSH_CONFIG" || warn 'Не удалось сделать копию SSH-конфига'
        if ask 'Запретить root-вход по SSH?'; then
            if [[ -z "$NEWUSER" ]] && ! id -nG "${SUDO_USER:-nobody}" 2>/dev/null | grep -qw sudo; then
                warn 'Новый sudo-пользователь не создан. Отключайте root только если уже проверен другой администратор.'
                if ! ask 'Всё равно продолжить?'; then :; else set_sshd_value PermitRootLogin no && SSH_CHANGED=yes; fi
            else set_sshd_value PermitRootLogin no && SSH_CHANGED=yes; fi
        fi
        if ask 'Сменить SSH-порт?'; then
            while true; do
                SSH_PORT=
                if prompt SSH_PORT 'Новый порт (1-65535): ' && valid_port "$SSH_PORT"; then break; fi
                error 'Введите число от 1 до 65535'
            done
            if (( SSH_PORT < 1024 )); then warn 'Порт ниже 1024 может конфликтовать с системными службами.'; fi
            set_sshd_value Port "$SSH_PORT" && SSH_CHANGED=yes
        fi
        if ask 'Ограничить попытки входа и время авторизации?'; then set_sshd_value MaxAuthTries 3 && set_sshd_value LoginGraceTime 30 && SSH_CHANGED=yes; fi
        if ask 'Отключить DebianBanner (не скрывает версию протокола OpenSSH)?'; then set_sshd_value DebianBanner no && SSH_CHANGED=yes; fi
    fi
fi

printf '\n[8/15] Firewall\n'
if ask 'Настроить UFW?'; then
    SSH_EFFECTIVE_PORT=${SSH_PORT:-$(sshd -T 2>/dev/null | awk '$1=="port" {print $2; exit}')}
    [[ -n "$SSH_EFFECTIVE_PORT" ]] || SSH_EFFECTIVE_PORT=22
    if ! ufw allow "$SSH_EFFECTIVE_PORT/tcp"; then error 'Не удалось разрешить SSH-порт; UFW не включается'; else
        if [[ "$SSH_EFFECTIVE_PORT" != 22 ]] && ask 'Оставить также открытым порт 22/tcp?'; then ufw allow 22/tcp || warn 'Не удалось открыть порт 22'; fi
        if [[ "$INSTALL_NGINX" == yes ]]; then ufw allow 80/tcp && ufw allow 443/tcp || warn 'Не удалось открыть HTTP/HTTPS'; fi
        extra_ports=
        if prompt extra_ports 'Дополнительные порты (например 53/udp 8080/tcp), Enter — пропустить: '; then
            for rule in $extra_ports; do
                if [[ "$rule" =~ ^[0-9]{1,5}(/(tcp|udp))?$ ]] && valid_port "${rule%%/*}"; then ufw allow "$rule" || warn "Не удалось открыть $rule"; else warn "Пропущено некорректное правило: $rule"; fi
            done
        fi
        ufw default deny incoming && ufw default allow outgoing
        if ufw --force enable; then success 'UFW включён; SSH-порт разрешён'; else error 'Не удалось включить UFW'; fi
    fi
fi

if [[ "$SSH_CHANGED" == yes ]]; then
    printf '\nПроверка SSH-конфигурации перед применением\n'
    if sshd -t 2>>"$LOG_FILE"; then
        if systemctl reload ssh 2>>"$LOG_FILE" || systemctl reload sshd 2>>"$LOG_FILE"; then
            SSH_RESTART_PENDING=no
            success 'Конфигурация SSH проверена и перечитана. Текущую сессию пока не закрывайте.'
        else
            SSH_RESTART_PENDING=yes
            error 'Не удалось перечитать SSH; конфиг сохранён, действующий процесс не был остановлен.'
        fi
    else
        error "sshd -t выявил ошибку. Настройки оставлены на диске и сохранена копия рядом с $SSH_CONFIG; автоматически откатите/исправьте конфиг до перезапуска."
        SSH_RESTART_PENDING=yes
    fi
fi

printf '\n[9/15] Fail2ban\n'
if command -v fail2ban-client >/dev/null 2>&1 && ask 'Включить и запустить fail2ban?'; then
    if systemctl enable --now fail2ban; then success 'fail2ban включён'; else error 'Не удалось запустить fail2ban'; fi
fi

printf '\n[10/15] TCP-настройки\n'
if ask 'Включить умеренные TCP-настройки (BBR только если доступен)?'; then
    if [[ -d /etc/sysctl.d ]]; then
        apply_sysctl net.core.default_qdisc fq || true
        if sysctl net.ipv4.tcp_available_congestion_control 2>/dev/null | grep -qw bbr; then apply_sysctl net.ipv4.tcp_congestion_control bbr || true; else warn 'BBR недоступен в текущем ядре; пропущен'; fi
        apply_sysctl net.ipv4.tcp_mtu_probing 1 || true
        success "Настройки записаны в $SYSCTL_FILE (отдельный файл, без перезаписи системного sysctl.conf)"
    else warn '/etc/sysctl.d отсутствует; настройки не менялись'; fi
fi

printf '\n[11/15] IP forwarding\n'
if ask 'Включить IP forwarding? Только для роутера/VPN/NAT.'; then apply_sysctl net.ipv4.ip_forward 1 && success 'IP forwarding включён' || error 'Не удалось применить IP forwarding'; fi

printf '\n[12/15] SYN cookies\n'
if ask 'Включить SYN cookies?'; then apply_sysctl net.ipv4.tcp_syncookies 1 && success 'SYN cookies включены' || warn 'Параметр не применён'; fi

printf '\n[13/15] DNS\n'
if ask 'Настроить DNS?'; then
    warn 'Ручное изменение /etc/resolv.conf отключено: файл часто управляется системой и может быть ссылкой.'
    if command -v resolvectl >/dev/null 2>&1; then
        warn 'Задайте DNS через netplan/NetworkManager либо systemd-resolved для конкретного интерфейса; этот скрипт не меняет DNS, чтобы не нарушить сеть.'
    else warn 'Измените DNS в сетевой конфигурации провайдера/системы (netplan, ifupdown или NetworkManager).'; fi
fi

printf '\n[14/15] Автоматические security-обновления\n'
if ask 'Включить unattended-upgrades?'; then
    if apt-get install -y unattended-upgrades && dpkg-reconfigure -f noninteractive unattended-upgrades; then
        systemctl enable --now apt-daily.timer apt-daily-upgrade.timer 2>>"$LOG_FILE" || warn 'Не удалось включить один из apt timers'
        success 'Автоматические обновления безопасности настроены'
    else error 'Не удалось настроить unattended-upgrades'; fi
fi

printf '\n[15/15] Nginx и ICMP\n'
if [[ "$INSTALL_NGINX" == yes ]]; then
    if ask 'Установить простую стартовую страницу nginx?'; then
        if [[ -e /var/www/html/index.html ]]; then backup /var/www/html/index.html || warn 'Не удалось сохранить старую index.html'; fi
        printf '%s\n' '<!doctype html><html lang="ru"><meta charset="utf-8"><title>Server</title><h1>Server is running</h1></html>' >/var/www/html/index.html
        if nginx -t 2>>"$LOG_FILE" && systemctl reload nginx; then success 'Стартовая страница nginx установлена'; else error 'Ошибка проверки/перезагрузки nginx'; fi
    fi
    if ask 'Скрыть server_tokens в nginx?'; then
        mkdir -p /etc/nginx/conf.d
        printf 'server_tokens off;\n' >/etc/nginx/conf.d/99-server-tokens.conf
        if nginx -t 2>>"$LOG_FILE" && systemctl reload nginx; then success 'server_tokens отключён'; else error 'Конфигурация nginx не прошла проверку'; fi
    fi
else log 'nginx не установлен; настройки nginx пропущены'; fi
if ask 'Игнорировать ICMP echo-запросы (ping)?'; then apply_sysctl net.ipv4.icmp_echo_ignore_all 1 && success 'ICMP echo отключён' || warn 'Не удалось применить настройку ICMP'; fi

printf '\n==== Завершение настройки ====\n'
if [[ -n "$NEWUSER$USER_PASSWORD$ROOT_PASS$SSH_PORT" ]]; then
    umask 077
    {
        printf '===== УЧЁТНЫЕ ДАННЫЕ =====\nДата: %s\n' "$(date -Is)"
        [[ -n "$NEWUSER" ]] && printf 'Пользователь: %s\nПароль пользователя: %s\n' "$NEWUSER" "$USER_PASSWORD"
        [[ -n "$ROOT_PASS" ]] && printf 'Пароль root: %s\n' "$ROOT_PASS"
        [[ -n "$SSH_PORT" ]] && printf 'Новый SSH-порт: %s\n' "$SSH_PORT"
    } >"$CREDS_FILE" && chmod 600 "$CREDS_FILE"
    printf '\nВАЖНО: новые данные доступа (скопируйте их в менеджер паролей):\n'
    [[ -n "$NEWUSER" ]] && printf 'Пользователь: %s\nПароль пользователя: %s\n' "$NEWUSER" "$USER_PASSWORD"
    [[ -n "$ROOT_PASS" ]] && printf 'Пароль root: %s\n' "$ROOT_PASS"
    [[ -n "$SSH_PORT" ]] && printf 'SSH-порт: %s\n' "$SSH_PORT"
    printf 'Защищённая копия: %s (права 600). Удалите её после сохранения: shred -u %q\n' "$CREDS_FILE" "$CREDS_FILE"
else
    printf 'Новые пароли/пользователи/порты не создавались.\n'
    if [[ -f "$CREDS_FILE" ]]; then printf 'Предыдущий файл учётных данных не изменён: %s\n' "$CREDS_FILE"; fi
fi
printf 'Лог: %s\n' "$LOG_FILE"
if [[ "$SSH_RESTART_PENDING" == yes ]]; then warn 'SSH-конфигурация требует ручной проверки до следующего перезапуска ssh.'; fi
if ask 'Перезагрузить сервер сейчас?'; then
    if [[ "$SSH_RESTART_PENDING" == yes ]]; then warn 'Перезагрузка может лишить доступа из-за неприменённой SSH-конфигурации.'; if ! ask 'Подтвердить перезагрузку несмотря на предупреждение?'; then exit 0; fi; fi
    reboot
else success 'Работа скрипта завершена'; fi
