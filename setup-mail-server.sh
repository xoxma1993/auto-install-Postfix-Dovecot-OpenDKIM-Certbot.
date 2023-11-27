#!/bin/bash

# Функция для логирования
log() {
    echo "[$(date +'%Y-%m-%dT%H:%M:%S%z')] $@"
}

# Функция для отката изменений
rollback() {
    log "Ошибка! Восстановление исходных файлов..."
    sudo cp -f /etc/postfix/main.cf.bak /etc/postfix/main.cf
    sudo cp -f /etc/dovecot/conf.d/10-mail.conf.bak /etc/dovecot/conf.d/10-mail.conf
    sudo rm -f /etc/dovecot/dovecot-users
    sudo rm -rf /etc/opendkim/keys/$DOMAIN
    log "Исходные файлы восстановлены."
    exit 1
}

# Запрос домена
read -p "Введите ваш домен (например, example.com): " DOMAIN
EMAIL="admin@$DOMAIN"

# Запрос пароля
read -sp "Введите ваш пароль: " PASSWORD
echo

# Создание резервных копий файлов конфигурации
sudo cp -f /etc/postfix/main.cf /etc/postfix/main.cf.bak
sudo cp -f /etc/dovecot/conf.d/10-mail.conf /etc/dovecot/conf.d/10-mail.conf.bak

# Обработка ошибок и откат изменений при ошибке
trap 'rollback' ERR

# Обновление и установка пакетов
log "Обновление системы и установка необходимых пакетов..."
sudo apt update && sudo apt install -y postfix dovecot-core dovecot-imapd opendkim opendkim-tools certbot

# Конфигурация Postfix
log "Настройка Postfix..."
sudo postconf -e "myhostname = $DOMAIN" &&
sudo postconf -e "mydestination = $DOMAIN, localhost.localdomain, localhost" &&
sudo postconf -e "mynetworks = 127.0.0.0/8, [::1]/128" &&
sudo postconf -e "inet_interfaces = all"

# Конфигурация Dovecot
log "Настройка Dovecot..."
DOVECOT_CONF="/etc/dovecot/conf.d/10-mail.conf"
echo "mail_location = mbox:~/mail:INBOX=/var/mail/%u" | sudo tee -a $DOVECOT_CONF

# Создание пользователя и пароля для Dovecot
log "Настройка аутентификации Dovecot..."
ENCRYPTED_PASS=$(doveadm pw -s SHA512-CRYPT -p "$PASSWORD")
echo "$EMAIL:$ENCRYPTED_PASS" | sudo tee /etc/dovecot/dovecot-users

# Создание и настройка ключей DKIM
log "Настройка DKIM..."
sudo mkdir -p /etc/opendkim/keys/$DOMAIN &&
sudo opendkim-genkey -b 2048 -D /etc/opendkim/keys/$DOMAIN -d $DOMAIN -s mail &&
sudo chown opendkim:opendkim /etc/opendkim/keys/$DOMAIN/* &&
sudo chmod 600 /etc/opendkim/keys/$DOMAIN/*

# Настройка OpenDKIM
OPENDKIM_CONF="/etc/opendkim.conf"
echo "Domain                  $DOMAIN" | sudo tee -a $OPENDKIM_CONF
echo "KeyFile                 /etc/opendkim/keys/$DOMAIN/mail.private" | sudo tee -a $OPENDKIM_CONF
echo "Selector                mail" | sudo tee -a $OPENDKIM_CONF

# Интеграция OpenDKIM с Postfix
log "Интеграция OpenDKIM с Postfix..."
sudo postconf -e "milter_default_action = accept" &&
sudo postconf -e "milter_protocol = 2" &&
sudo postconf -e "smtpd_milters = inet:localhost:12301" &&
sudo postconf -e "non_smtpd_milters = inet:localhost:12301"

# Получение SSL сертификата Let's Encrypt
log "Получение сертификата Let's Encrypt..."
sudo certbot certonly --standalone --preferred-challenges http -d $DOMAIN --agree-tos --non-interactive --email $EMAIL

# Настройка SSL для Postfix и Dovecot
log "Настройка SSL для Postfix и Dovecot..."
sudo postconf -e "smtpd_tls_cert_file = /etc/letsencrypt/live/$DOMAIN/fullchain.pem" &&
sudo postconf -e "smtpd_tls_key_file = /etc/letsencrypt/live/$DOMAIN/privkey.pem" &&
sudo postconf -e "smtpd_use_tls = yes"

echo "ssl_cert = </etc/letsencrypt/live/$DOMAIN/fullchain.pem" | sudo tee -a $DOVECOT_CONF
echo "ssl_key = </etc/letsencrypt/live/$DOMAIN/privkey.pem" | sudo tee -a $DOVECOT_CONF

# Перезапуск служб
log "Перезапуск служб..."
sudo systemctl restart postfix &&
sudo systemctl restart dovecot &&
sudo systemctl restart opendkim

# Очистка ловушки
trap - ERR

# Вывод информации для DNS-настройки
DKIM_RECORD=$(cat /etc/opendkim/keys/$DOMAIN/mail.txt | grep -v '^-' | tr -d '\n')
log "Добавьте следующие записи DNS для вашего домена $DOMAIN:"
echo "DKIM: mail._domainkey IN TXT \"v=DKIM1; k=rsa; p=$DKIM_RECORD\""
echo "SPF: @ IN TXT \"v=spf1 mx -all\""

# Вывод информации о портах
log "Используйте следующие порты для подключения:"
echo "IMAP (без SSL): 143"
echo "IMAP (с SSL): 993"
echo "SMTP (без SSL): 25"
echo "SMTP (с SSL/TLS): 587 (или 465)"

# Вывод информации о веб-интерфейсе и учетных данных
log "Информация для входа:"
echo "Логин: $EMAIL"
echo "Пароль: $PASSWORD"
