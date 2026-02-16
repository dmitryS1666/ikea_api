# 🏪 IKEA API

[![Ruby](https://img.shields.io/badge/Ruby-3.3.0-red.svg)](https://www.ruby-lang.org/)
[![Rails](https://img.shields.io/badge/Rails-7.1.6-red.svg)](https://rubyonrails.org/)
[![PostgreSQL](https://img.shields.io/badge/PostgreSQL-16-blue.svg)](https://www.postgresql.org/)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

RESTful API для работы с данными товаров IKEA. Приложение предоставляет JSON API для управления товарами, категориями, фильтрами и расчета доставки.

## 📋 Оглавление

- [Возможности](#-возможности)
- [Технологический стек](#-технологический-стек)
- [Быстрый старт](#-быстрый-старт)
- [Установка](#-установка)
- [Конфигурация](#-конфигурация)
- [API Документация](#-api-документация)
- [Деплой](#-деплой)
- [Архитектура](#-архитектура)
- [Разработка](#-разработка)

## ✨ Возможности

- 🔍 **Управление товарами** - CRUD операции для товаров IKEA
- 📂 **Категории** - Иерархическая структура категорий
- 🔎 **Фильтры** - Система фильтрации товаров
- 🚚 **Расчет доставки** - Автоматический расчет стоимости доставки
- 🔐 **Аутентификация** - JWT-based авторизация
- 📊 **Swagger документация** - Интерактивная документация API
- 🐳 **Docker поддержка** - Готовые конфигурации для разработки и production
- 🚀 **Kamal деплой** - Автоматический деплой через Kamal (MRSK)

## 🛠 Технологический стек

### Backend
- **Ruby** 3.3.0
- **Rails** 7.1.6 (API mode)
- **PostgreSQL** 16 - основная база данных
- **Redis** - кэширование и очереди
- **MongoDB** - синхронизация данных из парсера
- **Sidekiq** - фоновые задачи

### Инструменты
- **Fast JSON API** - сериализация JSON
- **JWT** - аутентификация
- **Kaminari** - пагинация
- **Rswag** - Swagger документация
- **Kamal** - деплой

## 🚀 Быстрый старт

### Через Docker (рекомендуется)

```bash
# 1. Клонирование репозитория
git clone https://github.com/dmitryS1666/ikea_api.git
cd ikea_api

# 2. Запуск всех сервисов
docker compose up -d

# 3. Настройка базы данных
docker compose exec app rails db:create db:migrate

# 4. Проверка работы
curl http://localhost:3000/up
```

### Локальная установка

```bash
# 1. Клонирование репозитория
git clone https://github.com/dmitryS1666/ikea_api.git
cd ikea_api

# 2. Установка зависимостей
bundle install

# 3. Настройка базы данных
rails db:create db:migrate

# 4. Запуск сервера
rails server
```

## 📦 Установка

### Требования

- Ruby 3.3.0
- PostgreSQL 16+
- Redis (опционально)
- Docker и Docker Compose (для Docker варианта)

### Шаг 1: Клонирование репозитория

```bash
git clone https://github.com/dmitryS1666/ikea_api.git
cd ikea_api
```

### Шаг 2: Установка зависимостей

```bash
# Установка гемов
bundle install
```

### Шаг 3: Настройка базы данных

```bash
# Создание базы данных
rails db:create

# Применение миграций
rails db:migrate

# Загрузка начальных данных (опционально)
rails db:seed
```

### Шаг 4: Настройка переменных окружения

Создайте файл `.env`:

```env
# База данных
DB_USERNAME=postgres
DB_PASSWORD=postgres
DB_HOST=localhost
DB_PORT=5432

# Redis
REDIS_URL=redis://localhost:6379/0

# MongoDB (для синхронизации)
MONGODB_URI=mongodb://localhost:27017/ikea

# JWT
JWT_SECRET=your_jwt_secret_here
```

Генерация JWT_SECRET:
```bash
ruby -e "require 'securerandom'; puts SecureRandom.hex(64)"
```

### Шаг 5: Запуск сервера

```bash
rails server
```

Приложение будет доступно по адресу: `http://localhost:3000`

## ⚙️ Конфигурация

### Переменные окружения

| Переменная | Описание | Обязательно |
|-----------|----------|-------------|
| `DB_USERNAME` | Имя пользователя PostgreSQL | Да |
| `DB_PASSWORD` | Пароль PostgreSQL | Да |
| `DB_HOST` | Хост базы данных | Да |
| `DB_PORT` | Порт базы данных | Нет (по умолчанию: 5432) |
| `REDIS_URL` | URL подключения к Redis | Нет |
| `MONGODB_URI` | URI подключения к MongoDB | Нет |
| `JWT_SECRET` | Секретный ключ для JWT | Да |

### База данных

Конфигурация базы данных находится в `config/database.yml`.

## 📚 API Документация

### Swagger UI

После запуска приложения документация доступна по адресу:
- **Swagger UI**: `http://localhost:3000/api-docs`
- **Swagger JSON**: `http://localhost:3000/api-docs/v1/swagger.yaml`

### Основные endpoints

#### Товары

```http
GET    /api/v1/products              # Список товаров
GET    /api/v1/products/:id          # Детали товара
GET    /api/v1/products/bestsellers   # Хиты продаж
GET    /api/v1/products/popular       # Популярные товары
```

#### Категории

```http
GET    /api/v1/categories            # Список категорий
GET    /api/v1/categories/:id         # Детали категории
GET    /api/v1/categories/popular     # Популярные категории
GET    /api/v1/categories/tree        # Дерево категорий
```

#### Аутентификация

```http
POST   /api/v1/auth/login             # Вход
POST   /api/v1/auth/register          # Регистрация
```

#### Доставка

```http
GET    /api/v1/delivery/types         # Типы доставки
POST   /api/v1/delivery/calculate     # Расчет стоимости
```

#### Health Check

```http
GET    /up                            # Проверка работоспособности
```

### Примеры запросов

#### Получение списка товаров

```bash
curl http://localhost:3000/api/v1/products
```

#### Вход в систему

```bash
curl -X POST http://localhost:3000/api/v1/auth/login \
  -H "Content-Type: application/json" \
  -d '{
    "username": "user",
    "password": "password"
  }'
```

#### Использование токена

```bash
curl http://localhost:3000/api/v1/products \
  -H "Authorization: Bearer YOUR_TOKEN"
```

## 🚀 Деплой

Проект настроен для деплоя через [Kamal](https://kamal-deploy.org).

### Быстрый старт

**Полная последовательность действий для первого деплоя:**

> ⚠️ **Важно:** Все команды выполняются на **локальной машине** (ваш компьютер), скрипты сами подключаются к серверу через SSH.

1. **Настройка сервера** (один раз)
   ```bash
   # На локальной машине (в директории проекта)
   sudo apt-get install sshpass  # Если еще не установлен
   chmod +x scripts/setup_server.sh
   ./scripts/setup_server.sh  # Скрипт сам подключится к серверу
   ```

2. **Настройка SSH ключей**
   ```bash
   # На локальной машине
   # Пользователь deploy создан без пароля, добавляем ключ через root:
   cat ~/.ssh/id_ed25519.pub | ssh root@45.135.234.22 \
     "mkdir -p /home/deploy/.ssh && \
      cat >> /home/deploy/.ssh/authorized_keys && \
      chown -R deploy:deploy /home/deploy/.ssh && \
      chmod 700 /home/deploy/.ssh && \
      chmod 600 /home/deploy/.ssh/authorized_keys"
   # Пароль для root: f8RpYS53tYgLPwnk
   ```

3. **Настройка доступа к GitHub**
   ```bash
   # На локальной машине
   chmod +x scripts/setup_github_access.sh
   ./scripts/setup_github_access.sh
   # Добавьте показанный ключ в GitHub: https://github.com/settings/keys
   ```

4. **Настройка Nginx**
   ```bash
   # На локальной машине
   chmod +x scripts/setup_nginx.sh
   ./scripts/setup_nginx.sh  # Скрипт сам подключится к серверу
   ```

5. **Подготовка секретов**
   ```bash
   mkdir -p .kamal
   
   # Генерация паролей
   DB_PASSWORD=$(openssl rand -base64 32)
   POSTGRES_PASSWORD=$DB_PASSWORD
   JWT_SECRET=$(ruby -e "require 'securerandom'; puts SecureRandom.hex(64)")
   RAILS_MASTER_KEY=$(rails secret)
   
   # Создание файла (замените YOUR_DOCKER_HUB_TOKEN на реальный токен)
   cat > .kamal/secrets << EOF
   RAILS_MASTER_KEY=$RAILS_MASTER_KEY
   DB_USERNAME=postgres
   DB_PASSWORD=$DB_PASSWORD
   REDIS_PASSWORD=
   JWT_SECRET=$JWT_SECRET
   POSTGRES_PASSWORD=$POSTGRES_PASSWORD
   KAMAL_REGISTRY_PASSWORD=YOUR_DOCKER_HUB_TOKEN
   EOF
   ```
   
   **Где взять Docker Hub токен:**
   - Перейдите: https://hub.docker.com/settings/security
   - Создайте "New Access Token"
   - Скопируйте токен и используйте как `KAMAL_REGISTRY_PASSWORD`
   
   **Подробная инструкция:** см. [SECRETS_GUIDE.md](./SECRETS_GUIDE.md)

6. **Установка Kamal**
   ```bash
   gem install kamal
   ```

7. **Деплой**
   ```bash
   kamal deploy
   ```

8. **Настройка базы данных**
   ```bash
   kamal app exec "rails db:create"
   kamal app exec "rails db:migrate"
   kamal app exec "rails db:seed"
   ```

### Документация по деплою

- **[DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md)** - Полное руководство с последовательностью действий

## 🏗️ Архитектура

### Структура проекта

```
ikea_api/
├── app/
│   ├── controllers/      # API контроллеры
│   ├── models/           # ActiveRecord модели
│   ├── serializers/      # JSON сериализаторы
│   └── services/         # Бизнес-логика
├── config/
│   ├── deploy.yml        # Конфигурация Kamal
│   ├── database.yml      # Конфигурация БД
│   └── routes.rb         # Маршруты API
├── db/
│   └── migrate/          # Миграции базы данных
├── scripts/              # Скрипты для деплоя
└── config/nginx/         # Конфигурация Nginx
```

### Поток данных

```
MongoDB (парсер) → PostgreSQL (API) → JSON API → Frontend
```

## 💻 Разработка

### Запуск тестов

```bash
# Все тесты
rspec

# Конкретный файл
rspec spec/models/product_spec.rb
```

### Генерация миграций

```bash
rails generate migration CreateTableName
```

### Rails консоль

```bash
rails console
```

### Полезные команды

```bash
# Просмотр маршрутов
rails routes

# Просмотр логов
tail -f log/development.log

# Очистка логов
rails log:clear
```

## 📖 Дополнительная документация

### Основная документация
- [DEPLOYMENT_GUIDE.md](./DEPLOYMENT_GUIDE.md) - **Полное руководство по деплою и настройке сервера**
- [SECRETS_GUIDE.md](./SECRETS_GUIDE.md) - Управление секретами и паролями
- [DOMAIN_SETUP.md](./DOMAIN_SETUP.md) - Настройка домена для Kamal

### Техническая документация
- [ADMIN_PANEL_OPTIONS.md](./ADMIN_PANEL_OPTIONS.md) - Варианты админ-панелей для проекта
- [SEO_SOLUTIONS.md](./SEO_SOLUTIONS.md) - Решения для SEO-оптимизации

## 🤝 Вклад в проект

1. Fork проекта
2. Создайте feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit изменения (`git commit -m 'Add some AmazingFeature'`)
4. Push в branch (`git push origin feature/AmazingFeature`)
5. Откройте Pull Request

## 📝 Лицензия

Этот проект распространяется под лицензией MIT. См. файл `LICENSE` для подробностей.

## 👥 Авторы

- **dmitryS1666** - [GitHub](https://github.com/dmitryS1666)

## 🙏 Благодарности

- Rails команда за отличный фреймворк
- Сообщество Kamal за инструменты деплоя
- Всем контрибьюторам проекта

---

# Тестовые сценарии
# 1. Конфигурация
TEST_EMAIL = "prod_test_#{Time.now.to_i}@example.com"
SKU_TO_TEST = Product.where('price > 0').first&.sku

unless SKU_TO_TEST
  puts "❌ Ошибка: Товары с ценой не найдены"
else
  puts "--- ЗАПУСК ПРОВЕРКИ (V3) ---"
  
  begin
    # 2. Создание пользователя
    user = User.create!(
      email: TEST_EMAIL,
      username: "test_#{Time.now.to_i}",
      password: SecureRandom.hex(10),
      phone: "+7#{rand(10**9..10**10-1)}"
    )
    puts "✅ 1. Пользователь создан"

    # 3. Создание заказа
    order = Order.create!(
      user: user,
      status: :completed,
      purchased_at: Time.current,
      total_amount: 10.0,
      full_name: "Final Check"
    )
    order.order_items.create!(product_sku: SKU_TO_TEST, quantity: 1, price: 10.0)
    puts "✅ 2. Заказ создан"

    # 4. Создание и публикация отзыва
    review = Review.create!(
      user: user,
      product_sku: SKU_TO_TEST,
      rating: 5,
      body: "Проверка системы отзывов. Все системы работают штатно."
    )
    review.published!
    puts "✅ 3. Отзыв опубликован"

    # 5. Проверка рейтинга
    product = Product.find_by(sku: SKU_TO_TEST)
    puts "📊 4. Рейтинг товара: #{product.rating_avg} (Отзывов: #{product.rating_count})"

  ensure
  
    # 6. ГАРАНТИРОВАННАЯ ОЧИСТКА В ПРАВИЛЬНОМ ПОРЯДКЕ
    puts "--- ОЧИСТКА ДАННЫХ ---"
    
    if defined?(review) && review&.persisted?
      review.destroy!
      puts "🗑️ Отзыв удален"
    end

    if defined?(user) && user&.persisted?
      # ВАЖНО: Удаляем заказы ПЕРЕД пользователем, чтобы не нарушить NOT NULL constraint
      user.orders.destroy_all
      user.destroy!
      puts "🗑️ Заказы и пользователь удалены"
    end

    ProductRatingCalculator.recalculate!(SKU_TO_TEST)
    final_p = Product.find_by(sku: SKU_TO_TEST)
    puts "✅ 5. Рейтинг восстановлен: #{final_p.rating_avg}"
    puts "--- ТЕСТ ЗАВЕРШЕН ---"
  end
end

# 1. Настройка
TEST_EMAIL = "cart_test_#{Time.now.to_i}@example.com"
SKU_1 = Product.where('price > 0').first&.sku
SKU_2 = Product.where('price > 0').last&.sku

puts "--- ЗАПУСК ТЕСТА КОРЗИНЫ (V3) ---"

begin
  # --- ШАГ 1: ГОСТЕВАЯ КОРЗИНА ---
  guest_token = SecureRandom.hex(24)
  guest_cart = Cart.create!(guest_token: guest_token)
  guest_cart.cart_items.create!(product_sku: SKU_1, quantity: 2)
  puts "✅ 1. Гостевая корзина создана (SKU: #{SKU_1}, Кол-во: 2)"

  # --- ШАГ 2: ПОЛЬЗОВАТЕЛЬ И ЕГО КОРЗИНА ---
  user = User.create!(
    email: TEST_EMAIL,
    username: "cart_user_#{Time.now.to_i}",
    password: "password123"
  )
  user_cart = user.create_cart!(guest_token: SecureRandom.hex(24))
  # Специально добавляем ТОТ ЖЕ SKU_1, чтобы проверить логику объединения
  user_cart.cart_items.create!(product_sku: SKU_1, quantity: 1)
  user_cart.cart_items.create!(product_sku: SKU_2, quantity: 1)
  puts "✅ 2. Корзина пользователя создана (SKU: #{SKU_1} (1шт), #{SKU_2} (1шт))"

  # --- ШАГ 3: ПРАВИЛЬНОЕ СЛИЯНИЕ (с учетом уникальности) ---
  puts "--- СЛИЯНИЕ ---"
  guest_cart.cart_items.each do |g_item|
    u_item = user_cart.cart_items.find_by(product_sku: g_item.product_sku)
    if u_item
      # Если товар уже есть, суммируем количество
      u_item.update!(quantity: u_item.quantity + g_item.quantity)
      g_item.destroy!
    else
      # Если товара нет, просто перепривязываем корзину
      g_item.update!(cart: user_cart)
    end
  end
  guest_cart.destroy!

  # --- ШАГ 4: ПРОВЕРКА ---
  user_cart.reload
  item_1 = user_cart.cart_items.find_by(product_sku: SKU_1)
  item_2 = user_cart.cart_items.find_by(product_sku: SKU_2)
  
  puts "📊 Итого в корзине:"
  user_cart.cart_items.each { |i| puts "   - SKU: #{i.product_sku}, Кол-во: #{i.quantity}" }

  if item_1&.quantity == 3 && item_2&.quantity == 1
    puts "🚀 ТЕСТ ПРОЙДЕН: Количества просуммированы, товары сохранены"
  else
    puts "❌ ТЕСТ ПРОВАЛЕН: Ошибка в расчете количества или потере данных"
  end

ensure
  # --- ОЧИСТКА ---
  puts "--- ОЧИСТКА ---"
  if defined?(user) && user&.persisted?
    user.cart&.destroy
    user.destroy!
    puts "🗑️ Тестовые данные удалены"
  end
  Cart.find_by(guest_token: guest_token)&.destroy
  puts "--- ЗАВЕРШЕНО ---"
end

Проверка работы АМО

bundle exec rails runner "
# 1. Загружаем окружение
File.readlines('.env').each { |l| k, v = l.strip.split('=', 2); ENV[k] = v if k && v } if File.exist?('.env')

puts '🚀 ЗАПУСК ФИНАЛЬНОЙ ПРОВЕРКИ ИНТЕГРАЦИИ'
puts '--------------------------------------'

# 2. Берем последнего пользователя
user = User.all.last
unless user
  puts '❌ Ошибка: В базе нет пользователей'
  return
end
puts \"👤 Пользователь: #{user.email || user.username}\"

# 3. Создаем тестовый заказ с товаром
order = Order.transaction do
  o = Order.create!(
    user: user,
    status: :created,
    total_amount: rand(100..500).to_f,
    full_name: 'Тест Проверки',
    phone: '+37529' + rand(1000000..9999999).to_s,
    delivery_type: 'pickup',
    payment_method: 'cash',
    address_json: { city: 'Minsk', note: 'Тестовая проверка интеграции' }
  )
  
  OrderItem.create!(
    order: o,
    product_sku: 'TEST.SKU.001',
    quantity: 1,
    price: o.total_amount
  )
  o
end
puts \"📦 Создан заказ №#{order.id} на сумму #{order.total_amount} BYN\"

# 4. Синхронизация
puts '--- Синхронизация с AmoCRM ---'
begin
  # Синхронизируем пользователя (создаем/обновляем контакт)
  user_sync = CrmIntegrationService.sync_user(user)
  print user_sync ? '✅ Контакт: OK | ' : '❌ Контакт: FAIL | '

  # Синхронизируем заказ (создаем сделку)
  order_sync = CrmIntegrationService.sync_order(order)
  if order_sync
    order.reload
    puts \"✅ Сделка: OK (ID: #{order.crm_external_id})\"
    puts '--------------------------------------'
    puts \"🎉 ПРОВЕРКА ЗАВЕРШЕНА УСПЕШНО!\"
    puts \"Проверьте сделку в AmoCRM по ссылке: https://#{ENV['AMO_CRM_SUBDOMAIN']}.amocrm.ru/leads/detail/#{order.crm_external_id}\"
  else
    puts '❌ Сделка: FAIL'
    puts 'Проверьте log/development.log или log/production.log для деталей.'
  end
rescue => e
  puts \"💥 Произошла ошибка: #{e.message}\"
  puts e.backtrace.first
end
"

---

**Сделано с ❤️ для работы с данными IKEA**
