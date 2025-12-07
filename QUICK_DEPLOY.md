# ⚡ Быстрый деплой через Kamal

## 🚀 Быстрый старт (5 шагов)

### 1. Установка Kamal

```bash
gem install kamal
```

### 2. Настройка сервера

```bash
# Установка sshpass (если нужно)
sudo apt-get install sshpass

# Автоматическая настройка сервера
chmod +x scripts/setup_server.sh
./scripts/setup_server.sh
```

### 3. Настройка SSH ключей

```bash
# Копирование SSH ключа на сервер
ssh-copy-id deploy@45.135.234.22

# Проверка подключения
ssh deploy@45.135.234.22
```

### 4. Настройка секретов

```bash
# Создание директории для секретов
mkdir -p .kamal

# Создание файла с секретами
cat > .kamal/secrets << EOL
RAILS_MASTER_KEY=$(rails secret)
DB_USERNAME=postgres
DB_PASSWORD=your_secure_password_here
REDIS_PASSWORD=
JWT_SECRET=$(ruby -e "require 'securerandom'; puts SecureRandom.hex(64)")
POSTGRES_PASSWORD=your_secure_postgres_password_here
EOL
```

### 5. Деплой

```bash
# Деплой приложения и всех сервисов
kamal deploy

# Или по отдельности
kamal accessory boot all  # PostgreSQL, Redis, MongoDB
kamal app deploy          # Приложение
```

## 📋 Настройка базы данных

```bash
# Создание БД
kamal app exec "rails db:create"

# Миграции
kamal app exec "rails db:migrate"
```

## 🔍 Проверка

```bash
# Статус
kamal app details

# Логи
kamal app logs

# Health check
curl http://45.135.234.22/up
```

**Подробная инструкция**: см. `DEPLOY_KAMAL.md`
