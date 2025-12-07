# 🌐 Настройка Nginx для Kamal деплоя

## 📋 Обзор

Nginx работает как reverse proxy:
- **API** (`/api/*`) → проксируется к Rails приложению в Docker (localhost:3000)
- **Frontend** (`/`) → статические файлы из `/var/www/ikea_frontend/dist`
- **Health check** (`/up`) → проверка работоспособности API

## 🚀 Быстрая настройка

### Автоматическая установка

```bash
# Сделайте скрипт исполняемым
chmod +x scripts/setup_nginx.sh

# Запустите настройку
./scripts/setup_nginx.sh
```

### Ручная установка

```bash
# 1. Подключение к серверу
ssh deploy@45.135.234.22

# 2. Установка Nginx
sudo apt-get update
sudo apt-get install -y nginx

# 3. Копирование конфигурации
# (с локальной машины)
scp config/nginx/ikea_api.conf deploy@45.135.234.22:/tmp/ikea_api.conf

# (на сервере)
sudo mv /tmp/ikea_api.conf /etc/nginx/sites-available/ikea_api
sudo ln -sf /etc/nginx/sites-available/ikea_api /etc/nginx/sites-enabled/ikea_api
sudo rm -f /etc/nginx/sites-enabled/default

# 4. Создание директории для фронтенда
sudo mkdir -p /var/www/ikea_frontend/dist
sudo chown -R deploy:deploy /var/www/ikea_frontend

# 5. Проверка и перезапуск
sudo nginx -t
sudo systemctl restart nginx
sudo systemctl enable nginx
```

## 📁 Структура конфигурации

### API Endpoints

```
http://45.135.234.22/api/*          → Rails API (Docker контейнер)
http://45.135.234.22/up              → Health check
http://45.135.234.22/api-docs        → Swagger документация
```

### Frontend

```
http://45.135.234.22/                → Статические файлы фронтенда
```

## 🔧 Настройка фронтенда

### Размещение собранного фронтенда

```bash
# На локальной машине (после сборки фронтенда)
rsync -avz dist/ deploy@45.135.234.22:/var/www/ikea_frontend/dist/

# Или через scp
scp -r dist/* deploy@45.135.234.22:/var/www/ikea_frontend/dist/
```

### Настройка API URL во фронтенде

Убедитесь, что фронтенд использует правильный URL для API:

```javascript
// Пример для Vue/React
const API_URL = process.env.NODE_ENV === 'production' 
  ? 'http://45.135.234.22/api'  // Временно через IP
  : 'http://localhost:3000/api';  // Для разработки
```

## 🌍 Настройка домена (в будущем)

### 1. Обновление конфигурации Nginx

```bash
# На сервере
sudo nano /etc/nginx/sites-available/ikea_api
```

Измените:
```nginx
server_name 45.135.234.22;  # Было
server_name your-domain.com www.your-domain.com;  # Станет
```

### 2. Настройка DNS

Добавьте A-запись в DNS:
```
your-domain.com     A    45.135.234.22
www.your-domain.com A    45.135.234.22
```

### 3. Настройка SSL через Let's Encrypt

```bash
# Установка certbot
sudo apt-get install -y certbot python3-certbot-nginx

# Получение сертификата
sudo certbot --nginx -d your-domain.com -d www.your-domain.com

# Автоматическое обновление
sudo certbot renew --dry-run
```

### 4. Обновление конфигурации Nginx для HTTPS

Раскомментируйте секцию HTTPS в `/etc/nginx/sites-available/ikea_api`:

```nginx
server {
    listen 443 ssl http2;
    server_name your-domain.com www.your-domain.com;
    
    ssl_certificate /etc/letsencrypt/live/your-domain.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/your-domain.com/privkey.pem;
    # ... остальная конфигурация
}

# Редирект HTTP → HTTPS
server {
    listen 80;
    server_name your-domain.com www.your-domain.com;
    return 301 https://$server_name$request_uri;
}
```

### 5. Перезапуск Nginx

```bash
sudo nginx -t
sudo systemctl reload nginx
```

## 🔍 Проверка работы

### Проверка API

```bash
# Health check
curl http://45.135.234.22/up

# API endpoints
curl http://45.135.234.22/api/v1/products
curl http://45.135.234.22/api/v1/categories

# Swagger
curl http://45.135.234.22/api-docs
```

### Проверка фронтенда

```bash
# Откройте в браузере
http://45.135.234.22/
```

### Проверка логов

```bash
# Логи Nginx
sudo tail -f /var/log/nginx/ikea_api_access.log
sudo tail -f /var/log/nginx/ikea_api_error.log

# Логи Rails приложения
kamal app logs -f
```

## 🛠️ Управление Nginx

```bash
# Статус
sudo systemctl status nginx

# Перезапуск
sudo systemctl restart nginx

# Перезагрузка конфигурации (без простоя)
sudo nginx -s reload

# Проверка конфигурации
sudo nginx -t

# Остановка
sudo systemctl stop nginx

# Запуск
sudo systemctl start nginx
```

## 🔒 Безопасность

### Firewall

```bash
# Разрешить только необходимые порты
sudo ufw allow 22/tcp    # SSH
sudo ufw allow 80/tcp    # HTTP
sudo ufw allow 443/tcp   # HTTPS
sudo ufw enable
```

### Ограничение доступа

Порт 3000 (Rails) доступен только через localhost, не открыт наружу.

### Rate Limiting (опционально)

Добавьте в конфигурацию Nginx:

```nginx
# В http блоке
limit_req_zone $binary_remote_addr zone=api_limit:10m rate=10r/s;

# В location /api
limit_req zone=api_limit burst=20 nodelay;
```

## 📊 Мониторинг

### Проверка подключений

```bash
# Активные подключения
sudo netstat -tulpn | grep :80
sudo netstat -tulpn | grep :3000
```

### Статистика Nginx

```bash
# Установка модуля статуса (опционально)
# Добавьте в конфигурацию:
# location /nginx_status {
#     stub_status on;
#     access_log off;
#     allow 127.0.0.1;
#     deny all;
# }
```

## 🔄 Обновление фронтенда

```bash
# После сборки нового фронтенда
rsync -avz --delete dist/ deploy@45.135.234.22:/var/www/ikea_frontend/dist/

# Или через git на сервере (если фронтенд в репозитории)
ssh deploy@45.135.234.22
cd /var/www/ikea_frontend
git pull
npm run build
# Файлы уже в dist/
```

## ❗ Решение проблем

### Ошибка 502 Bad Gateway

```bash
# Проверьте, что Rails приложение запущено
kamal app details

# Проверьте логи
kamal app logs
sudo tail -f /var/log/nginx/ikea_api_error.log
```

### Ошибка 404 для фронтенда

```bash
# Проверьте наличие файлов
ls -la /var/www/ikea_frontend/dist/

# Проверьте права доступа
sudo chown -R deploy:deploy /var/www/ikea_frontend
```

### Проблемы с CORS

Если фронтенд на другом домене, обновите CORS заголовки в Nginx конфигурации.

---

**Готово! Nginx настроен и работает с Kamal деплоем.** 🎉


