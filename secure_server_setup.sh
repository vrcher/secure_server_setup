#!/usr/bin/env bash
set -e

TIMESTAMP=$(date +%Y%m%d%H%M%S)

backup_file() {
FILE=$1
if [ -f "$FILE" ]; then
cp $FILE ${FILE}.bak.$TIMESTAMP
echo "Backup created: ${FILE}.bak.$TIMESTAMP"
fi
}

ask() {
read -p "$1 (y/n): " answer
[[ "$answer" == "y" || "$answer" == "Y" ]]
}

if [ "$EUID" -ne 0 ]; then
echo "Запустите скрипт от root"
exit
fi

echo "===== SERVER SECURITY SETUP ====="

################################
# 1 UPDATE SYSTEM
################################
if ask "1) Обновить систему?"; then
apt update && apt upgrade -y
fi

################################
# 2 INSTALL BASE PACKAGES
################################
if ask "2) Установить базовые пакеты?"; then
apt install -y nano htop net-tools unzip ufw fail2ban nginx
fi

################################
# 3 TIMEZONE
################################
if ask "3) Настроить таймзону?"; then
timedatectl
read -p "Введите таймзону (например Europe/Berlin): " TIMEZONE
timedatectl set-timezone $TIMEZONE
timedatectl
fi

################################
# 4 CREATE USER
################################
if ask "4) Создать нового пользователя?"; then

read -p "Введите имя пользователя: " NEWUSER

if id "$NEWUSER" &>/dev/null; then
echo "Пользователь уже существует"
else

useradd -m -s /bin/bash $NEWUSER

USER_PASSWORD=$(openssl rand -base64 12)

echo "$NEWUSER:$USER_PASSWORD" | chpasswd

usermod -aG sudo $NEWUSER

echo "Пользователь создан"

fi

fi

################################
# 5 DISABLE ROOT LOGIN
################################
if ask "5) Запретить вход root по SSH?"; then

backup_file /etc/ssh/sshd_config

sed -i 's/#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config

fi

################################
# 6 CHANGE SSH PORT
################################
if ask "6) Изменить SSH порт?"; then

read -p "Введите новый SSH порт: " SSH_PORT

backup_file /etc/ssh/sshd_config

sed -i "s/#Port 22/Port $SSH_PORT/" /etc/ssh/sshd_config

fi

################################
# SSH SECURITY LIMITS
################################
if ask "7) Ограничить попытки входа SSH?"; then

backup_file /etc/ssh/sshd_config

echo "MaxAuthTries 3" >> /etc/ssh/sshd_config
echo "LoginGraceTime 30" >> /etc/ssh/sshd_config

fi

################################
# HIDE SSH VERSION
################################
if ask "8) Скрыть версию SSH?"; then

backup_file /etc/ssh/sshd_config

echo "DebianBanner no" >> /etc/ssh/sshd_config

fi

################################
# RESTART SSH
################################
systemctl restart ssh

################################
# 9 FIREWALL
################################
if ask "9) Включить firewall UFW?"; then

ufw allow 22/tcp

if [ ! -z "$SSH_PORT" ]; then
ufw allow $SSH_PORT/tcp
fi

ufw allow 80/tcp
ufw allow 443/tcp

read -p "Добавить кастомные порты (через пробел) или Enter: " PORTS

for PORT in $PORTS; do
ufw allow $PORT
done

ufw --force enable
fi

################################
# 10 TCP OPTIMIZATION
################################
if ask "10) Оптимизация TCP сети?"; then

backup_file /etc/sysctl.conf

echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
echo "net.ipv4.tcp_fastopen=3" >> /etc/sysctl.conf
echo "net.ipv6.conf.all.disable_ipv6=1" >> /etc/sysctl.conf

sysctl -p

fi

################################
# 11 SYN FLOOD PROTECTION
################################
if ask "11) Включить защиту SYN flood?"; then

backup_file /etc/sysctl.conf

echo "net.ipv4.tcp_syncookies = 1" >> /etc/sysctl.conf

sysctl -p

fi

################################
# 12 DNS
################################
if ask "12) Настроить DNS?"; then

read -p "Введите DNS (например 1.1.1.1 8.8.8.8): " DNS

backup_file /etc/resolv.conf

> /etc/resolv.conf

for d in $DNS; do
echo "nameserver $d" >> /etc/resolv.conf
done

fi

################################
# 13 AUTO SECURITY UPDATES
################################
if ask "13) Включить автоматические security обновления?"; then

apt install unattended-upgrades -y
dpkg-reconfigure -plow unattended-upgrades

fi

################################
# 14 NGINX STUB PAGE
################################
if ask "14) Установить HTTP заглушку nginx?"; then

mkdir -p /var/www/html

cat > /var/www/html/index.html <<EOF
<html>
<head><title>Server</title></head>
<body>
<h1>Server works</h1>
</body>
</html>
EOF

nginx -t
systemctl restart nginx

fi

################################
# 15 HIDE NGINX VERSION
################################
if ask "15) Скрыть версию nginx?"; then

backup_file /etc/nginx/nginx.conf

sed -i '/http {/a server_tokens off;' /etc/nginx/nginx.conf

nginx -t
systemctl restart nginx

fi

################################
# 16 BLOCK PING
################################
if ask "16) Заблокировать ping?"; then

backup_file /etc/sysctl.conf

echo "net.ipv4.icmp_echo_ignore_all=1" >> /etc/sysctl.conf

sysctl -p

echo "Проверка параметра:"
sysctl net.ipv4.icmp_echo_ignore_all

echo "Тест ping localhost"
ping -c 2 127.0.0.1 || echo "Ping отключен"

fi

################################
# FINAL INFO
################################
echo
echo "===== ДАННЫЕ СЕРВЕРА ====="

if [ ! -z "$NEWUSER" ]; then
echo "Пользователь: $NEWUSER"
echo "Пароль: $USER_PASSWORD"
fi

if [ ! -z "$SSH_PORT" ]; then
echo "SSH порт: $SSH_PORT"
fi

echo "==========================="

################################
# REBOOT
################################
if ask "Перезагрузить сервер?"; then
reboot
else
echo "Скрипт завершен"
fi
