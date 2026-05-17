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

## Установка базовых пакетов

Устанавливаются:
bash, nano, htop, net-tools, unzip, ufw, fail2ban, nginx, unattended-upgrades, curl

Настройка таймзоны
Создание новой учетной записи (добавление в sudo, генерация случайного пароля)
Смена root пароля (генерация нового случайного пароля для root)
SSH Hardening
Запрет входа под root
Смена SSH порта (позволяет изменить стандартный SSH порт 22)
Ограничение попыток SSH
Скрытие версии SSH
Безопасный restart SSH
Automatic Security Updates
Ping Block (Блокировка ICMP ping)

Перед перезапуском выполняется проверка:
sshd -t
Firewall (UFW)

Скрипт:
включает UFW
открывает нужные порты
позволяет добавить кастомные порты
автоматически закрывает порт 22, если SSH был перенесен на другой порт

TCP / SYSCTL Optimization
Включает: BBR, fq, tcp_fastopen, SYN flood protection, network tuning

Примеры параметров:
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.ipv4.tcp_fastopen=3
DNS Configuration

Настройка кастомных DNS серверов:
1.1.1.1
8.8.8.8

Установка и настройка: unattended-upgrades, Nginx Setup

Скрипт может:
установить nginx
создать простую HTTP заглушку
скрыть версию nginx

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
Ubuntu, Debian

Установка и запуск
Через wget
wget -O secure.sh https://raw.githubusercontent.com/vrcher/secure_server_setup/main/secure_server_setup.sh && chmod +x secure.sh && sudo ./secure.sh
Через curl
curl -O https://raw.githubusercontent.com/vrcher/secure_server_setup/main/secure_server_setup.sh && chmod +x secure_server_setup.sh && sudo ./secure_server_setup.sh

Важно
После выполнения скрипта могут измениться
SSH порт, root login, firewall правила
НЕ закрывайте текущую SSH сессию после смены порта!

пока не убедитесь что новый вход работает.
