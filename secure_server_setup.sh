#!/bin/bash

set -e

log() { echo -e "\e[34m[INFO]\e[0m $1"; }
success() { echo -e "\e[32m[SUCCESS]\e[0m $1"; }
error() { echo -e "\e[31m[ERROR]\e[0m $1"; }

ask() {
read -p "$1 (y/n): " ans
[[ "$ans" == "y" || "$ans" == "Y" ]]
}

backup() {
file=$1
cp "$file" "$file.bak.$(date +%s)"
}

if [ "$EUID" -ne 0 ]; then
echo "Запустите скрипт от root"
exit
fi

echo "==== Secure Server Setup ===="

################################################
# 1 UPDATE
################################################

if ask "1) Обновить систему?"; then
log "Обновляем систему"
apt update && apt upgrade -y
success "Система обновлена"
fi

################################################
# 2 PACKAGES
################################################

BASE_PACKAGES="nano htop net-tools unzip ufw fail2ban nginx unattended-upgrades curl"

echo "Будут установлены пакеты:"
echo $BASE_PACKAGES

if ask "2) Установить базовые пакеты?"; then

log "Установка пакетов"

apt install -y $BASE_PACKAGES

success "Пакеты установлены"

fi

################################################
# 3 TIMEZONE
################################################

if ask "3) Установить таймзону?"; then

timedatectl

read -p "Введите таймзону: " TZ

timedatectl set-timezone "$TZ"

success "Таймзона установлена: $TZ"

fi

################################################
# 4 CREATE USER
################################################

if ask "4) Создать нового пользователя?"; then

read -p "Имя пользователя: " NEWUSER

if id "$NEWUSER" &>/dev/null; then

error "Пользователь уже существует"

else

USER_PASSWORD=$(openssl rand -base64 12)

useradd -m -s /bin/bash "$NEWUSER"

echo "$NEWUSER:$USER_PASSWORD" | chpasswd

usermod -aG sudo "$NEWUSER"

success "Пользователь создан"

fi

fi

################################################
# ROOT PASSWORD
################################################

if ask "5) Сменить пароль root?"; then

ROOT_PASS=$(openssl rand -base64 12)

echo "root:$ROOT_PASS" | chpasswd

success "Пароль root изменен"

fi

################################################
# SSH CONFIG
################################################

SSH_CONFIG="/etc/ssh/sshd_config"

################################################
# DISABLE ROOT LOGIN
################################################

if ask "6) Запретить вход root по SSH?"; then

backup $SSH_CONFIG

if grep -q "^PermitRootLogin" $SSH_CONFIG; then
sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' $SSH_CONFIG
else
echo "PermitRootLogin no" >> $SSH_CONFIG
fi

success "Root SSH login отключен"

fi

################################################
# CHANGE SSH PORT
################################################

if ask "7) Сменить SSH порт?"; then

read -p "Введите новый порт: " SSH_PORT

backup $SSH_CONFIG

if grep -q "^#Port 22" $SSH_CONFIG; then
sed -i "s/#Port 22/Port $SSH_PORT/" $SSH_CONFIG
elif grep -q "^Port" $SSH_CONFIG; then
sed -i "s/^Port.*/Port $SSH_PORT/" $SSH_CONFIG
else
echo "Port $SSH_PORT" >> $SSH_CONFIG
fi

success "SSH порт изменен на $SSH_PORT"

fi

################################################
# SSH LIMIT
################################################

if ask "8) Ограничить попытки SSH?"; then

backup $SSH_CONFIG

grep -q "MaxAuthTries" $SSH_CONFIG || echo "MaxAuthTries 3" >> $SSH_CONFIG
grep -q "LoginGraceTime" $SSH_CONFIG || echo "LoginGraceTime 30" >> $SSH_CONFIG

success "SSH лимиты установлены"

fi

################################################
# HIDE SSH VERSION
################################################

if ask "9) Скрыть версию SSH?"; then

backup $SSH_CONFIG

grep -q "DebianBanner" $SSH_CONFIG || echo "DebianBanner no" >> $SSH_CONFIG

success "SSH версия скрыта"

fi

log "Перезапуск SSH"

systemctl restart ssh

success "SSH перезапущен"

################################################
# FIREWALL
################################################

if ask "10) Настроить UFW firewall?"; then

ufw allow 22/tcp

[ ! -z "$SSH_PORT" ] && ufw allow $SSH_PORT/tcp

ufw allow 80
ufw allow 443

read -p "Дополнительные порты: " PORTS

for p in $PORTS; do
ufw allow $p
done

ufw --force enable

success "Firewall включен"

fi

################################################
# TCP OPTIMIZATION
################################################

SYSCTL="/etc/sysctl.conf"

if ask "11) Оптимизация TCP сети?"; then

backup $SYSCTL

grep -q "ip_forward = 1" $SYSCTL || echo "net.ipv4.ip_forward = 1" >> $SYSCTL
grep -q "default_qdisc = fq" $SYSCTL || echo "net.core.default_qdisc = fq" >> $SYSCTL
grep -q "tcp_congestion_control = bbr" $SYSCTL || echo "net.ipv4.tcp_congestion_control = bbr" >> $SYSCTL
grep -q "nf_conntrack_max" $SYSCTL || echo "net.netfilter.nf_conntrack_max = 524288" >> $SYSCTL
grep -q "rmem_max" $SYSCTL || echo "net.core.rmem_max = 16777216" >> $SYSCTL
grep -q "wmem_max" $SYSCTL || echo "net.core.wmem_max = 16777216" >> $SYSCTL
grep -q "tcp_rmem" $SYSCTL || echo "net.ipv4.tcp_rmem = 4096 87380 16777216" >> $SYSCTL
grep -q "tcp_wmem" $SYSCTL || echo "net.ipv4.tcp_wmem = 4096 65536 16777216" >> $SYSCTL
grep -q "tcp_mtu_probing" $SYSCTL || echo "net.ipv4.tcp_mtu_probing = 1" >> $SYSCTL
grep -q "accept_local" $SYSCTL || echo "net.ipv4.conf.all.accept_local = 1" >> $SYSCTL
grep -q "route_localnet" $SYSCTL || echo "net.ipv4.conf.all.route_localnet = 1" >> $SYSCTL
grep -q "netdev_max_backlog" $SYSCTL || echo "net.core.netdev_max_backlog = 250000" >> $SYSCTL
grep -q "tcp_slow_start_after_idle" $SYSCTL || echo "net.ipv4.tcp_slow_start_after_idle = 0" >> $SYSCTL
grep -q "tcp_tw_reuse" $SYSCTL || echo "net.ipv4.tcp_tw_reuse = 1" >> $SYSCTL
grep -q "tcp_max_syn_backlog" $SYSCTL || echo "net.ipv4.tcp_max_syn_backlog = 8192" >> $SYSCTL
grep -q "somaxconn" $SYSCTL || echo "net.core.somaxconn = 65535" >> $SYSCTL

sysctl -p

success "TCP оптимизация применена"

fi

################################################
# SYN FLOOD
################################################

if ask "12) Включить защиту SYN flood?"; then

backup $SYSCTL

grep -q "tcp_syncookies" $SYSCTL || echo "net.ipv4.tcp_syncookies=1" >> $SYSCTL

sysctl -p

success "SYN flood защита включена"

fi

################################################
# DNS
################################################

if ask "13) Настроить DNS?"; then

read -p "Введите DNS (пример 1.1.1.1 8.8.8.8): " DNS

backup /etc/resolv.conf

> /etc/resolv.conf

for d in $DNS; do
echo "nameserver $d" >> /etc/resolv.conf
done

success "DNS настроен"

fi

################################################
# AUTO UPDATES
################################################

if ask "14) Включить авто security обновления?"; then

apt install unattended-upgrades -y
dpkg-reconfigure -plow unattended-upgrades

success "Автообновления включены"

fi

################################################
# NGINX STUB
################################################

if ask "15) Установить nginx заглушку?"; then

mkdir -p /var/www/html

cat > /var/www/html/index.html <<EOF
<html>
<head><title>Server</title></head>
<body>
<h1>Server is running</h1>
</body>
</html>
EOF

nginx -t
systemctl restart nginx

success "nginx работает"

fi

################################################
# HIDE NGINX VERSION
################################################

if ask "16) Скрыть версию nginx?"; then

backup /etc/nginx/nginx.conf

grep -q "server_tokens off" /etc/nginx/nginx.conf || sed -i '/http {/a server_tokens off;' /etc/nginx/nginx.conf

nginx -t
systemctl restart nginx

success "Версия nginx скрыта"

fi

################################################
# BLOCK PING
################################################

if ask "17) Заблокировать ping?"; then

backup $SYSCTL

grep -q "icmp_echo_ignore_all" $SYSCTL || echo "net.ipv4.icmp_echo_ignore_all=1" >> $SYSCTL

sysctl -p

log "Проверка ping"

ping -c 2 127.0.0.1 || log "Ping отключен"

fi

################################################
# FINAL INFO
################################################

echo
echo "===== ДАННЫЕ ====="

[ ! -z "$NEWUSER" ] && echo "User: $NEWUSER"
[ ! -z "$USER_PASSWORD" ] && echo "User password: $USER_PASSWORD"

[ ! -z "$ROOT_PASS" ] && echo "Root password: $ROOT_PASS"

[ ! -z "$SSH_PORT" ] && echo "SSH port: $SSH_PORT"

echo "=================="

################################################
# REBOOT
################################################

if ask "Перезагрузить сервер?"; then
reboot
else
success "Скрипт завершен"
fi
