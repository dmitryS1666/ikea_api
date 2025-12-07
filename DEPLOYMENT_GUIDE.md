# 🚀 Руководство по деплою и настройке продакшн-сервера

## 📋 Очередность действий

### Часть 1: Настройка продакшн-сервера (один раз)

#### Шаг 1: Подготовка сервера
```bash
# Подключение к серверу
ssh root@45.135.234.22
# Пароль: f8RpYS53tYgLPwnk

# Автоматическая настройка (рекомендуется)
chmod +x scripts/setup_server.sh
./scripts/setup_server.sh
```

**Что делает скрипт:**
- Устанавливает Docker и Docker Compose
- Создает пользователя `deploy`
- Настраивает SSH доступ
- Предоставляет права Docker для пользователя `deploy`

#### Шаг 2: Настройка SSH ключей
```bash
# На локальной машине
ssh-keygen -t ed25519 -C "deploy@ikea_back"
ssh-copy-id deploy@45.135.234.22

# Проверка подключения
ssh deploy@45.135.234.22
```

#### Шаг 3: Настройка доступа к GitHub
```bash
# На локальной машине
chmod +x scripts/setup_github_access.sh
./scripts/setup_github_access.sh

# Скопируйте показанный публичный ключ
# Добавьте его в GitHub: https://github.com/settings/keys

# Проверка доступа
ssh deploy@45.135.234.22 'ssh -T git@github.com'
```

#### Шаг 4: Настройка Nginx
```bash
# На локальной машине
chmod +x scripts/setup_nginx.sh
./scripts/setup_nginx.sh
```

**Или вручную:**
```bash
# На сервере
ssh deploy@45.135.234.22
sudo apt-get update
sudo apt-get install -y nginx

# Копирование конфигурации
sudo cp config/nginx/ikea_api.conf /etc/nginx/sites-available/ikea_api
sudo ln -sf /etc/nginx/sites-available/ikea_api /etc/nginx/sites-enabled/ikea_api
sudo rm -f /etc/nginx/sites-enabled/default

# Создание директории для фронтенда
sudo mkdir -p /var/www/ikea_frontend/dist
sudo chown -R deploy:deploy /var/www/ikea_frontend

# Проверка и перезапуск
sudo nginx -t
sudo systemctl restart nginx
sudo systemctl enable nginx
```

---

### Часть 2: Деплой приложения (каждый раз при обновлении)

#### Шаг 1: Подготовка секретов
```bash
# На локальной машине
mkdir -p .kamal

# Создание файла с секретами
cat > .kamal/secrets << EOF
RAILS_MASTER_KEY=$(rails secret)
DB_USERNAME=postgres
DB_PASSWORD=your_secure_password_here
REDIS_PASSWORD=
JWT_SECRET=$(ruby -e "require 'securerandom'; puts SecureRandom.hex(64)")
POSTGRES_PASSWORD=your_secure_postgres_password_here
EOF

# Убедитесь, что файл не попадет в git
echo ".kamal/secrets" >> .gitignore
```

#### Шаг 2: Установка Kamal (если еще не установлен)
```bash
gem install kamal
kamal version
```

#### Шаг 3: Проверка конфигурации
```bash
# Просмотр конфигурации
kamal config

# Проверка подключения к серверу
kamal app details
```

#### Шаг 4: Первый деплой
```bash
# Деплой всех сервисов (PostgreSQL, Redis, MongoDB, приложение)
kamal deploy

# Или по отдельности:
kamal accessory boot all  # PostgreSQL, Redis, MongoDB
kamal app deploy          # Приложение
```

#### Шаг 5: Настройка базы данных (только при первом деплое)
```bash
# Создание базы данных
kamal app exec "rails db:create"

# Применение миграций
kamal app exec "rails db:migrate"

# Загрузка начальных данных (создание админа)
kamal app exec "rails db:seed"
```

#### Шаг 6: Проверка работы
```bash
# Health check
curl http://45.135.234.22/up

# API endpoints
curl http://45.135.234.22/api/v1/products

# Swagger (требует авторизации)
curl http://45.135.234.22/api-docs
```

---

### Часть 3: Обновление приложения (при изменениях в коде)

```bash
# 1. Обновление кода локально
git pull origin main

# 2. Деплой обновлений
kamal deploy

# 3. При необходимости выполните миграции
kamal app exec "rails db:migrate"
```

---

## 📊 Полная последовательность для первого деплоя

### На локальной машине:

1. **Клонирование репозитория** (если еще не клонирован)
   ```bash
   git clone https://github.com/dmitryS1666/ikea_api.git
   cd ikea_api
   ```

2. **Настройка сервера** (один раз)
   ```bash
   chmod +x scripts/setup_server.sh
   ./scripts/setup_server.sh
   ```

3. **Настройка SSH ключей**
   ```bash
   ssh-copy-id deploy@45.135.234.22
   ```

4. **Настройка доступа к GitHub**
   ```bash
   chmod +x scripts/setup_github_access.sh
   ./scripts/setup_github_access.sh
   # Добавьте ключ в GitHub
   ```

5. **Настройка Nginx**
   ```bash
   chmod +x scripts/setup_nginx.sh
   ./scripts/setup_nginx.sh
   ```

6. **Подготовка секретов**
   ```bash
   mkdir -p .kamal
   cat > .kamal/secrets << EOF
   RAILS_MASTER_KEY=$(rails secret)
   DB_USERNAME=postgres
   DB_PASSWORD=your_secure_password_here
   REDIS_PASSWORD=
   JWT_SECRET=$(ruby -e "require 'securerandom'; puts SecureRandom.hex(64)")
   POSTGRES_PASSWORD=your_secure_postgres_password_here
   EOF
   ```

7. **Установка Kamal**
   ```bash
   gem install kamal
   ```

8. **Первый деплой**
   ```bash
   kamal deploy
   ```

9. **Настройка базы данных**
   ```bash
   kamal app exec "rails db:create"
   kamal app exec "rails db:migrate"
   kamal app exec "rails db:seed"
   ```

10. **Проверка работы**
    ```bash
    curl http://45.135.234.22/up
    ```

---

## 🔄 Последующие деплои

```bash
# 1. Обновление кода
git pull origin main

# 2. Деплой
kamal deploy

# 3. Миграции (если есть)
kamal app exec "rails db:migrate"
```

---

## 🛠️ Полезные команды

### Управление приложением
```bash
# Статус
kamal app details

# Логи
kamal app logs -f

# Rails консоль
kamal app exec "rails console"

# Перезапуск
kamal app restart
```

### Управление сервисами
```bash
# Статус всех сервисов
kamal accessory details all

# Логи PostgreSQL
kamal accessory logs postgres

# Логи Redis
kamal accessory logs redis

# Логи MongoDB
kamal accessory logs mongodb
```

---

## 📚 Дополнительная документация

- **DEPLOY_KAMAL.md** - Детальная инструкция по деплою через Kamal
- **NGINX_SETUP.md** - Подробная настройка Nginx
- **README.md** - Общая информация о проекте
- **README_DOCKER.md** - Работа с Docker локально

---

## ⚠️ Важные замечания

1. **Секреты**: Файл `.kamal/secrets` содержит конфиденциальную информацию и не должен попадать в git
2. **Пароли**: Обязательно измените все пароли по умолчанию в production
3. **Firewall**: Настройте firewall для ограничения доступа к портам
4. **SSL**: В будущем настройте SSL сертификат для домена
5. **Резервное копирование**: Настройте регулярное резервное копирование базы данных

