# Secure Server Setup V3

Интерактивный bash-скрипт для базовой настройки и hardening Linux серверов на Debian/Ubuntu.

Скрипт автоматизирует:
- первичную настройку сервера
- безопасность SSH
- firewall
- TCP/sysctl оптимизацию
- настройку nginx
- автоматические security обновления
- базовый hardening системы

Подходит для:
- VPS/VDS
- Dedicated servers
- Proxy/VPN серверов
- Web серверов
- Docker host
- Homelab

---

# Возможности

## Обновление системы
- `apt update`
- `apt upgrade -y`

---

## Установка базовых пакетов

Устанавливаются:

```bash
nano
htop
net-tools
unzip
ufw
fail2ban
nginx
unattended-upgrades
curl
Настройка таймзоны

Скрипт позволяет установить timezone сервера:

timedatectl set-timezone Europe/Berlin
Создание новой учетной записи
создание пользователя
добавление в sudo
генерация случайного пароля
Смена root пароля
генерация нового случайного пароля для root
SSH Hardening
Запрет входа под root
PermitRootLogin no
Смена SSH порта

Позволяет изменить стандартный SSH порт 22.

Ограничение попыток SSH
MaxAuthTries 3
LoginGraceTime 30
Скрытие версии SSH
DebianBanner no
Безопасный restart SSH

Перед перезапуском выполняется проверка:

sshd -t
Firewall (UFW)

Скрипт:

включает UFW
открывает нужные порты
позволяет добавить кастомные порты
автоматически закрывает порт 22, если SSH был перенесен на другой порт
TCP / SYSCTL Optimization

Включает:

BBR
fq
tcp_fastopen
SYN flood protection
network tuning

Примеры параметров:

net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen=3
DNS Configuration

Настройка кастомных DNS серверов:

1.1.1.1
8.8.8.8
Automatic Security Updates

Установка и настройка:

unattended-upgrades
Nginx Setup

Скрипт может:

установить nginx
создать простую HTTP заглушку
скрыть версию nginx
server_tokens off;
Ping Block

Блокировка ICMP ping:

net.ipv4.icmp_echo_ignore_all=1
Service Restart Logic

Сервисы перезапускаются только если:

были внесены изменения
конфиг успешно прошел проверку
Особенности
Безопасный повторный запуск

Скрипт можно запускать повторно:

строки не дублируются
изменения не применяются при ответе n
службы не перезапускаются без изменений
Backup конфигов

Перед изменением файлов создаются backup копии:

/etc/ssh/sshd_config.bak.TIMESTAMP
Поддерживаемые системы
Ubuntu 20.04+
Ubuntu 22.04+
Debian 11+
Debian 12+
Установка и запуск
Через wget
wget -O secure.sh https://raw.githubusercontent.com/vrcher/secure_server_setup/main/secure_server_setup.sh && chmod +x secure.sh && sudo ./secure.sh
Через curl
curl -O https://raw.githubusercontent.com/vrcher/secure_server_setup/main/secure_server_setup.sh && chmod +x secure_server_setup.sh && sudo ./secure_server_setup.sh
Важно

После выполнения скрипта могут измениться:

SSH порт
root login
firewall правила
НЕ закрывайте текущую SSH сессию,

пока не убедитесь что новый вход работает.
