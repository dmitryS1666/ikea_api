# 🚀 JavaScript Parser Deployment Guide (Linux)

## 📋 Обзор

Это руководство описывает разворачивание Node.js парсера IKEA на Linux сервере с использованием PM2, MongoDB, Nginx и systemd.

---

## 🎯 Требования

- Linux сервер (Ubuntu 20.04+ / Debian 11+ / CentOS 8+)
- Root или sudo доступ
- Минимум 4GB RAM (рекомендуется 8GB)
- 50GB+ свободного места на диске (для изображений и данных)

---

## 📦 Шаг 1: Установка системных зависимостей

### Ubuntu/Debian

```bash
# Обновление системы
sudo apt-get update
sudo apt-get upgrade -y

# Установка базовых зависимостей
sudo apt-get install -y \
  curl \
  git \
  build-essential \
  libssl-dev \
  ca-certificates \
  gnupg \
  lsb-release
```

## 🟢 Шаг 2: Установка Node.js

### Используя NodeSource (рекомендуется)

```bash
# Для Node.js 20.x
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt-get install -y nodejs  # Ubuntu/Debian

### Используя NVM (альтернатива)

```bash
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.0/install.sh | bash
source ~/.bashrc
nvm install 20
nvm use 20
nvm alias default 20
```

### Проверка установки

```bash
node -v  # => v20.x.x
npm -v   # => 10.x.x
```

---

## 🍃 Шаг 3: Установка MongoDB

### Ubuntu/Debian

```bash
# Импорт ключа MongoDB
curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | \
  sudo gpg -o /usr/share/keyrings/mongodb-server-7.0.gpg --dearmor

# Добавление репозитория
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | \
  sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list

# Установка MongoDB
sudo apt-get update
sudo apt-get install -y mongodb-org

# Запуск службы
sudo systemctl start mongod
sudo systemctl enable mongod
```

### CentOS/RHEL

```bash
# Создание файла репозитория
sudo tee /etc/yum.repos.d/mongodb-org-7.0.repo << EOF
[mongodb-org-7.0]
name=MongoDB Repository
baseurl=https://repo.mongodb.org/yum/redhat/\$releasever/mongodb-org/7.0/x86_64/
gpgcheck=1
enabled=1
gpgkey=https://www.mongodb.org/static/pgp/server-7.0.asc
EOF

# Установка
sudo yum install -y mongodb-org
sudo systemctl start mongod
sudo systemctl enable mongod
```

### Настройка MongoDB

```bash
# Подключение к MongoDB
mongosh

# Создание пользователя администратора
use admin
db.createUser({
  user: "admin",
  pwd: "your_secure_password",
  roles: [ { role: "userAdminAnyDatabase", db: "admin" } ]
})

# Создание пользователя для приложения
use ikea
db.createUser({
  user: "ikea_user",
  pwd: "your_app_password",
  roles: [ { role: "readWrite", db: "ikea" } ]
})

exit
```

### Включение аутентификации

```bash
sudo nano /etc/mongod.conf
```

```yaml
security:
  authorization: enabled
```

```bash
sudo systemctl restart mongod
```

---

## 📁 Шаг 4: Развертывание приложения

### 1. Создание пользователя для приложения

```bash
sudo adduser --disabled-password --gecos "" nodejs
sudo mkdir -p /var/www/ikea_parser
sudo chown nodejs:nodejs /var/www/ikea_parser
```

### 2. Клонирование репозитория

```bash
sudo -u nodejs -i
cd /var/www/ikea_parser
git clone https://github.com/your-username/ikea_parser.git .
```

### 3. Установка зависимостей

```bash
cd /var/www/ikea_parser
npm install --production
```

### 4. Настройка переменных окружения

```bash
# Создание .env файла
nano /var/www/ikea_parser/.env
```

```env
# .env
NODE_ENV=production
PORT=3000
MONGODB_URI=mongodb://ikea_user:your_app_password@localhost:27017/ikea?authSource=ikea
JWT_SECRET=your_jwt_secret_here
TELEGRAM_BOT_TOKEN=your_telegram_bot_token
TELEGRAM_CHAT_ID=your_telegram_chat_id
GCLOUD_PROJECT=your_gcloud_project_id
SHOP_URL=https://your-shop-url.com
DEEPL_API_KEY=your_deepl_api_key  # Опционально
```

Генерация JWT_SECRET:

```bash
node -e "console.log(require('crypto').randomBytes(64).toString('hex'))"
```

### 5. Создание директорий

```bash
mkdir -p /var/www/ikea_parser/src/public/images/products
mkdir -p /var/www/ikea_parser/exports
mkdir -p /var/www/ikea_parser/cache
chmod -R 755 /var/www/ikea_parser/src/public/images
```

---

## 🔧 Шаг 5: Установка и настройка PM2

### 1. Установка PM2

```bash
sudo npm install -g pm2
```

### 2. Создание конфигурации PM2

```bash
nano /var/www/ikea_parser/ecosystem.config.cjs
```

```javascript
module.exports = {
  apps: [{
    name: 'ikea-parser',
    script: './src/index.js',
    instances: 1,
    exec_mode: 'fork',
    env: {
      NODE_ENV: 'production',
      PORT: 3000
    },
    error_file: './logs/pm2-error.log',
    out_file: './logs/pm2-out.log',
    log_file: './logs/pm2-combined.log',
    time: true,
    autorestart: true,
    max_memory_restart: '1G',
    node_args: '--max-old-space-size=2048'
  }]
};
```

### 3. Создание директории для логов

```bash
mkdir -p /var/www/ikea_parser/logs
```

### 4. Запуск приложения через PM2

```bash
cd /var/www/ikea_parser
pm2 start ecosystem.config.cjs
pm2 save
```

### 5. Настройка автозапуска PM2

```bash
pm2 startup systemd
# Выполните команду, которую выведет PM2 (обычно с sudo)
```

---

## 🌐 Шаг 6: Настройка Nginx

### 1. Установка Nginx

```bash
sudo apt-get install -y nginx  # Ubuntu/Debian
```

### 2. Создание конфигурации

```bash
sudo nano /etc/nginx/sites-available/ikea-parser
```

```nginx
# API сервер
upstream ikea_parser_api {
  server localhost:3000;
}

server {
  listen 80;
  server_name api.yourdomain.com;

  # Логи
  access_log /var/log/nginx/ikea-parser-access.log;
  error_log /var/log/nginx/ikea-parser-error.log;

  # Прокси для API
  location /api {
    proxy_pass http://ikea_parser_api;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection 'upgrade';
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_cache_bypass $http_upgrade;
    proxy_read_timeout 300s;
    proxy_connect_timeout 75s;
  }

  # Статические файлы (изображения)
  location /images {
    alias /var/www/ikea_parser/src/public/images;
    expires 1y;
    add_header Cache-Control "public, immutable";
  }

  # Экспорты
  location /exports {
    alias /var/www/ikea_parser/exports;
    add_header Content-Disposition "attachment";
  }

  # Админ-панель (Vue.js)
  location /admin-vue {
    alias /var/www/ikea_parser/admin-vue/dist;
    try_files $uri $uri/ /admin-vue/index.html;
  }

  # Обработка ошибок
  error_page 500 502 503 504 /50x.html;
  location = /50x.html {
    root /usr/share/nginx/html;
  }

  client_max_body_size 100M;
}
```

### 3. Активация конфигурации

```bash
sudo ln -s /etc/nginx/sites-available/ikea-parser /etc/nginx/sites-enabled/
sudo nginx -t  # Проверка конфигурации
sudo systemctl restart nginx
sudo systemctl enable nginx
```

---

## 🔒 Шаг 7: Настройка SSL (Let's Encrypt)

```bash
# Установка Certbot
sudo apt-get install -y certbot python3-certbot-nginx

# Получение сертификата
sudo certbot --nginx -d api.yourdomain.com

# Автоматическое обновление
sudo certbot renew --dry-run
```

---

## 🔐 Шаг 8: Настройка файрвола

```bash
# UFW (Ubuntu)
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw enable

# firewalld (CentOS)
sudo firewall-cmd --permanent --add-service=ssh
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --reload
```

---

## 📊 Шаг 9: Настройка cron задач

### 1. Редактирование crontab

```bash
sudo crontab -e -u nodejs
```

### 2. Добавление задач

```cron
# Ежедневная синхронизация в 02:00
0 2 * * * cd /var/www/ikea_parser && /usr/bin/node src/scripts/fetchCategories.js >> /var/www/ikea_parser/logs/cron.log 2>&1

# Еженедельная полная перезагрузка в воскресенье в 03:00
0 3 * * 0 cd /var/www/ikea_parser && /usr/bin/node src/scripts/reloadAllData.js >> /var/www/ikea_parser/logs/cron.log 2>&1

# Ежедневный экспорт в 08:00
0 8 * * * cd /var/www/ikea_parser && /usr/bin/node src/scripts/exportToYML.js >> /var/www/ikea_parser/logs/cron.log 2>&1
```

---

## 🏗️ Шаг 10: Сборка админ-панели (Vue.js)

```bash
cd /var/www/ikea_parser
cd admin-vue
npm install
npm run build
cd ..
```

---

## 🛠️ Шаг 11: Полезные команды

### Управление PM2

```bash
# Статус
pm2 status

# Логи
pm2 logs ikea-parser

# Перезапуск
pm2 restart ikea-parser

# Остановка
pm2 stop ikea-parser

# Мониторинг
pm2 monit
```

### Обновление приложения

```bash
cd /var/www/ikea_parser
git pull
npm install --production
pm2 restart ikea-parser
```

### Просмотр логов

```bash
# PM2 логи
pm2 logs ikea-parser --lines 100

# Nginx логи
sudo tail -f /var/log/nginx/ikea-parser-access.log
sudo tail -f /var/log/nginx/ikea-parser-error.log

# MongoDB логи
sudo tail -f /var/log/mongodb/mongod.log
```

### Ручной запуск скриптов

```bash
# Синхронизация категорий
cd /var/www/ikea_parser
node src/scripts/fetchCategories.js

# Синхронизация товаров
node src/scripts/fetchProducts.js "" 10

# Загрузка изображений
node src/scripts/downloadProductImages.js

# Экспорт данных
node src/scripts/exportToYML.js
```

---

## 🐛 Решение проблем

### PM2 не запускается

```bash
# Проверка логов
pm2 logs ikea-parser --err

# Проверка переменных окружения
pm2 env 0

# Перезапуск с очисткой
pm2 delete ikea-parser
pm2 start ecosystem.config.cjs
```

### MongoDB не подключается

```bash
# Проверка статуса
sudo systemctl status mongod

# Проверка подключения
mongosh -u ikea_user -p your_app_password --authenticationDatabase ikea

# Проверка логов
sudo tail -f /var/log/mongodb/mongod.log
```

### Nginx 502 Bad Gateway

```bash
# Проверка, что приложение запущено
pm2 status

# Проверка порта
sudo netstat -tlnp | grep 3000

# Проверка логов Nginx
sudo tail -f /var/log/nginx/ikea-parser-error.log
```

### Недостаточно памяти

```bash
# Увеличение лимита памяти в PM2
pm2 restart ikea-parser --update-env --node-args="--max-old-space-size=4096"

# Или в ecosystem.config.cjs
node_args: '--max-old-space-size=4096'
```

### Проблемы с изображениями

```bash
# Проверка прав доступа
sudo chown -R nodejs:nodejs /var/www/ikea_parser/src/public/images
sudo chmod -R 755 /var/www/ikea_parser/src/public/images

# Проверка свободного места
df -h
```

---

## 📈 Мониторинг и оптимизация

### 1. Установка мониторинга (опционально)

```bash
# PM2 Plus (облачный мониторинг)
pm2 link your_secret_key your_public_key

# Или локальный мониторинг
pm2 install pm2-server-monit
```

### 2. Настройка резервного копирования

```bash
# Создание скрипта бэкапа
nano /var/www/ikea_parser/scripts/backup.sh
```

```bash
#!/bin/bash
BACKUP_DIR="/var/backups/ikea_parser"
DATE=$(date +%Y%m%d_%H%M%S)

mkdir -p $BACKUP_DIR

# Бэкап MongoDB
mongodump --uri="mongodb://ikea_user:password@localhost:27017/ikea?authSource=ikea" \
  --out=$BACKUP_DIR/mongodb_$DATE

# Бэкап изображений
tar -czf $BACKUP_DIR/images_$DATE.tar.gz /var/www/ikea_parser/src/public/images

# Удаление старых бэкапов (старше 7 дней)
find $BACKUP_DIR -type f -mtime +7 -delete
```

```bash
chmod +x /var/www/ikea_parser/scripts/backup.sh

# Добавление в cron (ежедневно в 04:00)
0 4 * * * /var/www/ikea_parser/scripts/backup.sh
```

---

## 📚 Дополнительные ресурсы

- [PM2 Documentation](https://pm2.keymetrics.io/docs/)
- [MongoDB Documentation](https://docs.mongodb.com/)
- [Nginx Documentation](https://nginx.org/en/docs/)
- [Node.js Best Practices](https://github.com/goldbergyoni/nodebestpractices)

---

**Примечание**: Замените `yourdomain.com`, пароли и другие значения на реальные для вашего окружения. Регулярно обновляйте зависимости и следите за безопасностью.

