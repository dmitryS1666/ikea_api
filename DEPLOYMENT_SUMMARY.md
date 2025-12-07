# 📋 Краткая сводка по деплою

## 🎯 Очередность действий

### 1️⃣ Настройка продакшн-сервера (один раз)

```
1. Настройка сервера (Docker, пользователь deploy)
   → scripts/setup_server.sh

2. Настройка SSH ключей
   → ssh-copy-id deploy@45.135.234.22

3. Настройка доступа к GitHub
   → scripts/setup_github_access.sh

4. Настройка Nginx
   → scripts/setup_nginx.sh
```

### 2️⃣ Деплой приложения

```
1. Подготовка секретов
   → .kamal/secrets

2. Установка Kamal
   → gem install kamal

3. Деплой
   → kamal deploy

4. Настройка БД (только первый раз)
   → kamal app exec "rails db:create db:migrate db:seed"
```

### 3️⃣ Обновление приложения

```
1. git pull origin main
2. kamal deploy
3. kamal app exec "rails db:migrate" (если есть миграции)
```

---

## 📚 Подробные инструкции

- **DEPLOYMENT_GUIDE.md** - Полное руководство с пошаговыми инструкциями
- **DEPLOY_KAMAL.md** - Детальная документация по Kamal
- **NGINX_SETUP.md** - Настройка Nginx

---

## ⚡ Быстрая команда для первого деплоя

```bash
# 1. Настройка сервера
./scripts/setup_server.sh
ssh-copy-id deploy@45.135.234.22
./scripts/setup_github_access.sh
./scripts/setup_nginx.sh

# 2. Подготовка секретов
mkdir -p .kamal
cat > .kamal/secrets << EOF
RAILS_MASTER_KEY=$(rails secret)
DB_USERNAME=postgres
DB_PASSWORD=your_password
REDIS_PASSWORD=
JWT_SECRET=$(ruby -e "require 'securerandom'; puts SecureRandom.hex(64)")
POSTGRES_PASSWORD=your_postgres_password
EOF

# 3. Деплой
gem install kamal
kamal deploy
kamal app exec "rails db:create db:migrate db:seed"
```
