# 🚀 Rails API Deployment Guide (Linux)

## 📋 Обзор

Это руководство описывает разворачивание Rails API приложения на Linux сервере с использованием PostgreSQL, Nginx, Passenger, Redis и asdf.

---

## 🎯 Требования

- Ubuntu сервер (20.04+ или 22.04+)
- Root или sudo доступ
- Минимум 2GB RAM
- 20GB свободного места на диске

---

## 📦 Шаг 1: Установка системных зависимостей

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
  libreadline-dev \
  zlib1g-dev \
  libyaml-dev \
  libsqlite3-dev \
  sqlite3 \
  libxml2-dev \
  libxslt1-dev \
  libcurl4-openssl-dev \
  software-properties-common \
  libffi-dev \
  nodejs \
  yarn \
  openssh-server
```

---

## 👤 Шаг 2: Создание пользователя deploy и настройка SSH

### 1. Создание пользователя deploy

```bash
# Создание пользователя без пароля (доступ только по SSH ключу)
sudo adduser --disabled-password --gecos "" deploy

# Добавление пользователя в группу sudo (опционально, если нужны права sudo)
sudo usermod -aG sudo deploy
```

### 2. Настройка SSH ключей

```bash
# Переключение на пользователя deploy
sudo su - deploy

# Создание директории .ssh
mkdir -p ~/.ssh
chmod 700 ~/.ssh

# Создание файла authorized_keys
touch ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
```

### 3. Добавление публичного SSH ключа

**На локальной машине (разработчика):**

```bash
# Если у вас еще нет SSH ключа, создайте его
ssh-keygen -t ed25519 -C "your_email@example.com"

# Просмотр публичного ключа
cat ~/.ssh/id_ed25519.pub
```

**На сервере (как пользователь deploy):**

```bash
# Скопируйте содержимое публичного ключа в authorized_keys
nano ~/.ssh/authorized_keys
# Вставьте публичный ключ (одна строка)
```

**Или с локальной машины:**

```bash
# Копирование ключа на сервер
ssh-copy-id deploy@your_server_ip

# Или вручную:
cat ~/.ssh/id_ed25519.pub | ssh deploy@your_server_ip "mkdir -p ~/.ssh && cat >> ~/.ssh/authorized_keys"
```

### 4. Настройка SSH для безопасности

```bash
# Редактирование конфигурации SSH
sudo nano /etc/ssh/sshd_config
```

Рекомендуемые настройки:
```conf
# Отключение входа по паролю (только ключи)
PasswordAuthentication no
PubkeyAuthentication yes

# Отключение root входа
PermitRootLogin no

# Разрешить только пользователя deploy
AllowUsers deploy
```

```bash
# Перезапуск SSH
sudo systemctl restart sshd

# Проверка подключения с локальной машины
ssh deploy@your_server_ip
```

### 5. Создание структуры директорий для приложения

```bash
# Переключение на пользователя deploy
sudo su - deploy

# Создание структуры директорий
mkdir -p ~/apps/ikea_store
cd ~/apps/ikea_store
```

---

## 🐘 Шаг 3: Установка PostgreSQL

```bash
# Установка PostgreSQL
sudo apt-get install -y postgresql postgresql-contrib libpq-dev

# Запуск службы
sudo systemctl start postgresql
sudo systemctl enable postgresql

# Создание пользователя и базы данных
sudo -u postgres psql << EOF
CREATE USER ikea_store_user WITH PASSWORD 'your_secure_password';
CREATE DATABASE ikea_store_production OWNER ikea_store_user;
ALTER USER ikea_store_user CREATEDB;
\q
EOF
```

**Примечание**: Замените `your_secure_password` на надежный пароль.

## 💎 Шаг 4: Установка Ruby 3.3.0 через asdf

**Выполняйте все команды от имени пользователя deploy:**

```bash
# Подключение к серверу
ssh deploy@your_server_ip
```

### 1. Установка asdf

```bash
# Клонирование asdf
git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.0

# Добавление в .bashrc
echo '. "$HOME/.asdf/asdf.sh"' >> ~/.bashrc
echo '. "$HOME/.asdf/completions/asdf.bash"' >> ~/.bashrc
source ~/.bashrc

# Проверка установки
asdf --version
```

### 2. Установка плагинов

```bash
# Плагин для Ruby
asdf plugin add ruby https://github.com/asdf-vm/asdf-ruby.git

# Плагин для Node.js (если нужен)
asdf plugin add nodejs https://github.com/asdf-vm/asdf-nodejs.git
```

### 3. Установка зависимостей для Ruby

```bash
sudo apt-get install -y \
  autoconf \
  patch \
  build-essential \
  rustc \
  libssl-dev \
  libyaml-dev \
  libreadline6-dev \
  zlib1g-dev \
  libgmp-dev \
  libncurses5-dev \
  libffi-dev \
  libgdbm6 \
  libdb-dev \
  libxml2-dev \
  libxslt-dev \
  libcurl4-openssl-dev

### 4. Установка Ruby 3.3.0

```bash
# Установка Ruby
asdf install ruby 3.3.0
asdf global ruby 3.3.0

# Проверка
ruby -v  # => ruby 3.3.0
gem -v
```

### 5. Настройка .tool-versions (опционально)

```bash
# Создание файла для автоматического выбора версий
cd ~/apps/ikea_store
echo "ruby 3.3.0" > .tool-versions
```

---

## 🔴 Шаг 5: Установка Redis

```bash
# Установка Redis
sudo apt-get install -y redis-server

# Запуск службы
sudo systemctl start redis-server
sudo systemctl enable redis-server

# Проверка
redis-cli ping  # => PONG
```

### Настройка Redis

```bash
# Редактирование конфигурации
sudo nano /etc/redis/redis.conf
```

Основные настройки:
```conf
# Максимальный объем памяти (например, 512MB)
maxmemory 512mb
maxmemory-policy allkeys-lru

# Сохранение на диск
save 900 1
save 300 10
save 60 10000

# Пароль (опционально, но рекомендуется)
requirepass your_redis_password
```

```bash
# Перезапуск Redis
sudo systemctl restart redis-server
```

### Проверка работы Redis

```bash
redis-cli
> AUTH your_redis_password  # Если установлен пароль
> SET test "Hello Redis"
> GET test
> exit
```

---

## 🚂 Шаг 6: Установка Rails (для пользователя deploy)

```bash
# Переключение на пользователя deploy
sudo su - deploy

# Установка Rails
gem install rails -v 8.0.0
gem install bundler
rails -v  # => Rails 8.0.0
```

---

## 📁 Шаг 7: Развертывание приложения

**Все команды выполняются от имени пользователя deploy:**

```bash
# Подключение к серверу
ssh deploy@your_server_ip
```

### 1. Создание структуры директорий для Capistrano

```bash
# Создание директорий для Capistrano
mkdir -p ~/apps/ikea_store/{shared,releases}
mkdir -p ~/apps/ikea_store/shared/{log,tmp/pids,tmp/cache,tmp/sockets,public/uploads}
```

### 2. Клонирование репозитория (первоначальное развертывание)

```bash
cd ~/apps/ikea_store
git clone https://github.com/your-username/ikea_store.git current
cd current
```

### 3. Установка зависимостей

```bash
bundle install --deployment --without development test
```

### 4. Настройка переменных окружения

```bash
# Создание .env файла в shared директории
nano ~/apps/ikea_store/shared/.env
```

```env
# .env
RAILS_ENV=production
SECRET_KEY_BASE=your_secret_key_base_here
DATABASE_URL=postgresql://ikea_store_user:your_secure_password@localhost/ikea_store_production
REDIS_URL=redis://localhost:6379/0
REDIS_PASSWORD=your_redis_password  # Если установлен пароль
```

Генерация SECRET_KEY_BASE:

```bash
cd ~/apps/ikea_store/current
rails secret
# Скопируйте результат в ~/apps/ikea_store/shared/.env
```

### 5. Создание символической ссылки на .env

```bash
# Создание символической ссылки из current в shared
ln -s ~/apps/ikea_store/shared/.env ~/apps/ikea_store/current/.env
```

### 6. Настройка базы данных

```bash
cd ~/apps/ikea_store/current
RAILS_ENV=production rails db:create
RAILS_ENV=production rails db:migrate
RAILS_ENV=production rails db:seed  # Если есть seed данные
```

### 7. Предкомпиляция ассетов

```bash
RAILS_ENV=production rails assets:precompile
```

### 8. Установка прав доступа

```bash
# Убедитесь, что все файлы принадлежат пользователю deploy
sudo chown -R deploy:deploy ~/apps/ikea_store
chmod -R 755 ~/apps/ikea_store
```

---

## 🚂 Шаг 8: Установка и настройка Passenger

**Выполняйте от имени root или с sudo:**

### 1. Установка через APT (рекомендуется)

```bash
# Установка ключа
sudo apt-key adv --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys 561F9B9CAC40B2F7

# Добавление репозитория
sudo sh -c 'echo deb https://oss-binaries.phusionpassenger.com/apt/passenger $(lsb_release -cs) main > /etc/apt/sources.list.d/passenger.list'

# Обновление и установка
sudo apt-get update
sudo apt-get install -y nginx libnginx-mod-http-passenger
```

### 3. Проверка установки

```bash
passenger-config --version
passenger-status
```

---

## 🌐 Шаг 9: Настройка Nginx с Passenger

### 1. Создание конфигурации Nginx

```bash
sudo nano /etc/nginx/sites-available/ikea-store
```

```nginx
server {
  listen 80;
  server_name api.yourdomain.com;
  root /home/deploy/apps/ikea_store/current/public;

  # Логи
  access_log /var/log/nginx/ikea-store-access.log;
  error_log /var/log/nginx/ikea-store-error.log;

  # Passenger конфигурация
  passenger_enabled on;
  passenger_ruby /home/deploy/.asdf/shims/ruby;
  passenger_app_env production;
  passenger_min_instances 2;
  passenger_max_pool_size 6;
  passenger_pre_start http://api.yourdomain.com;

  # Статические файлы
  location ~ ^/(assets|packs)/ {
    expires 1y;
    add_header Cache-Control "public, immutable";
    access_log off;
  }

  # Обработка ошибок
  error_page 500 502 503 504 /500.html;
  client_max_body_size 4G;
  keepalive_timeout 10;
}
```

### 2. Настройка основного конфига Nginx

```bash
sudo nano /etc/nginx/nginx.conf
```

Добавьте в секцию `http`:

```nginx
http {
  # ... существующие настройки ...
  
  # Passenger конфигурация
  passenger_root /usr/lib/ruby/vendor_ruby/phusion_passenger/locations.ini;
  passenger_ruby /home/deploy/.asdf/shims/ruby;
  
  # Или если Passenger установлен через gem:
  # passenger_root /home/deploy/.asdf/installs/ruby/3.3.0/lib/ruby/gems/3.3.0/gems/passenger-8.x.x;
  # passenger_ruby /home/deploy/.asdf/shims/ruby;
}
```

### 3. Активация конфигурации

```bash
sudo ln -s /etc/nginx/sites-available/ikea-store /etc/nginx/sites-enabled/
sudo nginx -t  # Проверка конфигурации
sudo systemctl restart nginx
sudo systemctl enable nginx
```

---

## 🔒 Шаг 10: Настройка SSL (Let's Encrypt)

### 1. Установка Certbot

```bash
sudo apt-get install -y certbot python3-certbot-nginx
```

### 2. Получение сертификата

```bash
sudo certbot --nginx -d api.yourdomain.com
```

### 3. Автоматическое обновление

```bash
sudo certbot renew --dry-run
```

---

## 🔐 Шаг 11: Настройка файрвола

```bash
# UFW (Ubuntu)
sudo ufw allow 22/tcp    # SSH
sudo ufw allow 80/tcp    # HTTP
sudo ufw allow 443/tcp   # HTTPS
sudo ufw enable

# Проверка статуса
sudo ufw status
```

---

## 📊 Шаг 12: Мониторинг и логи

### 1. Просмотр статуса Passenger

```bash
sudo passenger-status
sudo passenger-memory-stats
```

### 2. Просмотр логов Nginx

```bash
sudo tail -f /var/log/nginx/ikea-store-access.log
sudo tail -f /var/log/nginx/ikea-store-error.log
```

### 3. Просмотр логов Rails

```bash
sudo tail -f /home/deploy/apps/ikea_store/current/log/production.log
# Или как пользователь deploy
tail -f ~/apps/ikea_store/current/log/production.log
```

---

## 🔄 Шаг 13: Автоматическое развертывание (Capistrano)

### 1. Добавление Capistrano в Gemfile

```ruby
# Gemfile
group :development do
  gem 'capistrano', '~> 3.17'
  gem 'capistrano-asdf'
  gem 'capistrano-bundler'
  gem 'capistrano-rails'
  gem 'capistrano-passenger'
end
```

### 2. Инициализация Capistrano

```bash
bundle install
cap install
```

### 3. Настройка Capfile

```ruby
# Capfile
require 'capistrano/asdf'
require 'capistrano/bundler'
require 'capistrano/rails'
require 'capistrano/passenger'
```

### 4. Настройка deploy.rb

```ruby
# config/deploy.rb
set :application, 'ikea_store'
set :repo_url, 'https://github.com/your-username/ikea_store.git'
set :deploy_to, '/home/deploy/apps/ikea_store'
set :user, 'deploy'
set :asdf_ruby_version, '3.3.0'
set :linked_files, %w[.env]
set :linked_dirs, %w[log tmp/pids tmp/cache tmp/sockets public/uploads]

# Passenger
set :passenger_restart_with_touch, true
```

### 5. Развертывание

```bash
cap production deploy
```

---

## 🛠️ Шаг 14: Полезные команды

### Перезапуск приложения

```bash
# Через touch (рекомендуется)
touch /home/deploy/apps/ikea_store/current/tmp/restart.txt

# Или через Passenger
sudo passenger-config restart-app /home/deploy/apps/ikea_store/current

# Или перезапуск Nginx
sudo systemctl restart nginx
```

### Проверка статуса

```bash
# Статус Passenger
sudo passenger-status

# Статус Nginx
sudo systemctl status nginx

# Статус Redis
sudo systemctl status redis-server
```

### Обновление кода (ручное, без Capistrano)

```bash
# Подключение к серверу
ssh deploy@your_server_ip

# Переход в директорию приложения
cd ~/apps/ikea_store/current

# Обновление кода
git pull origin main  # или master, в зависимости от вашей ветки

# Установка зависимостей
bundle install --deployment --without development test

# Миграции базы данных
RAILS_ENV=production rails db:migrate

# Предкомпиляция ассетов
RAILS_ENV=production rails assets:precompile

# Перезапуск приложения
touch tmp/restart.txt
```

### Работа с Redis

```bash
# Подключение к Redis
redis-cli
# или с паролем
redis-cli -a your_redis_password

# Очистка кэша
redis-cli FLUSHDB

# Мониторинг
redis-cli MONITOR
```

### Очистка старых релизов (Capistrano)

```bash
cap production deploy:cleanup
```

---

## 🐛 Решение проблем

### Passenger не запускается

```bash
# Проверка логов Passenger
sudo tail -f /home/deploy/apps/ikea_store/current/log/production.log
sudo tail -f /var/log/nginx/error.log

# Проверка статуса
sudo passenger-status
sudo passenger-memory-stats

# Проверка прав доступа
sudo chown -R deploy:deploy /home/deploy/apps/ikea_store
sudo chmod -R 755 /home/deploy/apps/ikea_store

# Проверка конфигурации
sudo nginx -t
```

### Ошибки базы данных

```bash
# Проверка подключения
sudo -u postgres psql -U ikea_store_user -d ikea_store_production

# Проверка миграций
cd ~/apps/ikea_store/current
RAILS_ENV=production rails db:migrate:status
```

### Nginx 502 Bad Gateway

```bash
# Проверка статуса Passenger
sudo passenger-status

# Проверка логов
sudo tail -f /var/log/nginx/error.log
sudo tail -f /home/deploy/apps/ikea_store/current/log/production.log

# Проверка прав доступа
sudo chown -R deploy:deploy /home/deploy/apps/ikea_store
sudo chmod -R 755 /home/deploy/apps/ikea_store/current/public

# Перезапуск Passenger
sudo passenger-config restart-app /home/deploy/apps/ikea_store/current
```

### Проблемы с Redis

```bash
# Проверка статуса
sudo systemctl status redis-server

# Проверка подключения
redis-cli ping

# Проверка логов
sudo tail -f /var/log/redis/redis-server.log

# Перезапуск Redis
sudo systemctl restart redis-server
```

### Проблемы с asdf

```bash
# Проверка версии Ruby
asdf current ruby

# Переустановка Ruby
asdf uninstall ruby 3.3.0
asdf install ruby 3.3.0

# Обновление asdf
asdf update
```

---

## 🔍 Шаг 15: Настройка Redis для поиска

### 1. Добавление Redis в Gemfile

```ruby
# Gemfile
gem 'redis', '~> 5.0'
gem 'redis-namespace'
gem 'redis-rails'  # Опционально
```

### 2. Настройка Redis в Rails

```ruby
# config/application.rb
config.cache_store = :redis_cache_store, {
  url: ENV['REDIS_URL'],
  password: ENV['REDIS_PASSWORD'],
  namespace: 'ikea_api',
  expires_in: 1.hour
}
```

### 3. Использование Redis для кэширования поиска

```ruby
# app/services/search_service.rb
class SearchService
  def self.search(query, page: 1, per_page: 20)
    cache_key = "search:#{query}:#{page}:#{per_page}"
    
    Rails.cache.fetch(cache_key, expires_in: 1.hour) do
      Product.where("name ILIKE ? OR name_ru ILIKE ?", 
                    "%#{query}%", "%#{query}%")
            .page(page)
            .per(per_page)
            .to_a
    end
  end
end
```

### 4. Индексация данных в Redis (опционально)

```ruby
# lib/tasks/redis_index.rake
namespace :redis do
  desc "Index products in Redis for fast search"
  task index_products: :environment do
    Product.find_each do |product|
      # Индексация по названию
      product.name.split.each do |word|
        Redis.current.sadd("search_index:#{word.downcase}", product.id)
      end
      
      # Индексация по русскому названию
      if product.name_ru.present?
        product.name_ru.split.each do |word|
          Redis.current.sadd("search_index_ru:#{word.downcase}", product.id)
        end
      end
    end
  end
end
```

---

## 📚 Дополнительные ресурсы

- [Rails Deployment Guide](https://guides.rubyonrails.org/deployment.html)
- [Passenger Documentation](https://www.phusionpassenger.com/docs/)
- [Nginx Documentation](https://nginx.org/en/docs/)
- [Redis Documentation](https://redis.io/docs/)
- [asdf Documentation](https://asdf-vm.com/)
- [Capistrano Documentation](http://capistranorb.com/)

---

**Примечание**: Замените `yourdomain.com`, пароли и другие значения на реальные для вашего окружения.

