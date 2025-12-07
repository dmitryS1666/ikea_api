# 🐳 Запуск через Docker

## Быстрый старт

### 1. Запуск всех сервисов

```bash
docker compose up -d
```

**Примечание**: Используйте `docker compose` (без дефиса) для новых версий Docker, или `docker-compose` для старых версий.

Это запустит:
- PostgreSQL (база данных) на порту 5432
- Redis (кэш) на порту 6379
- MongoDB (синхронизация) на порту 27017
- Rails приложение на порту 3000

### 2. Настройка базы данных

```bash
# Создание БД и применение миграций
docker compose exec app rails db:create db:migrate
```

### 3. Проверка работы

```bash
# Health check
curl http://localhost:3000/up

# Или откройте в браузере
# http://localhost:3000/api-docs
```

## Полезные команды

```bash
# Просмотр логов
docker compose logs -f app

# Остановка
docker compose stop

# Перезапуск
docker compose restart

# Остановка и удаление
docker compose down

# Rails консоль
docker compose exec app rails console

# Выполнение миграций
docker compose exec app rails db:migrate

# Пересборка образов
docker compose build
```

## Переменные окружения

Создайте файл `.env` для настройки:

```env
JWT_SECRET=your_jwt_secret_here
```

Генерация JWT_SECRET:
```bash
ruby -e "require 'securerandom'; puts SecureRandom.hex(64)"
```

