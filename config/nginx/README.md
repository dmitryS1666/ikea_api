# 🌐 Конфигурация Nginx

## Структура

- `ikea_api.conf` - основная конфигурация для API и Frontend

## Установка

### На сервере

```bash
# Копирование конфигурации
sudo cp config/nginx/ikea_api.conf /etc/nginx/sites-available/ikea_api

# Активация
sudo ln -sf /etc/nginx/sites-available/ikea_api /etc/nginx/sites-enabled/ikea_api

# Удаление дефолтной конфигурации
sudo rm -f /etc/nginx/sites-enabled/default

# Проверка
sudo nginx -t

# Перезапуск
sudo systemctl restart nginx
```

## Конфигурация

### API Endpoints

- `/api/*` - проксируется к Rails приложению (localhost:3000)
- `/up` - health check endpoint
- `/api-docs` - Swagger документация

### Frontend

- `/` - статические файлы из `/var/www/ikea_frontend/dist`
- Поддержка SPA (Single Page Application) через `try_files`

### Порты

- **80** - HTTP (временно через IP)
- **443** - HTTPS (после настройки домена и SSL)

## Обновление для домена

Когда добавите домен:

1. Обновите `server_name` в конфигурации:
   ```nginx
   server_name your-domain.com www.your-domain.com;
   ```

2. Настройте SSL:
   ```bash
   sudo certbot --nginx -d your-domain.com
   ```

3. Раскомментируйте секцию HTTPS в конфигурации

## Логи

- Access log: `/var/log/nginx/ikea_api_access.log`
- Error log: `/var/log/nginx/ikea_api_error.log`

## Мониторинг

```bash
# Просмотр логов в реальном времени
sudo tail -f /var/log/nginx/ikea_api_error.log

# Статус Nginx
sudo systemctl status nginx

# Перезагрузка конфигурации
sudo nginx -s reload
```


