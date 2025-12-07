# 🚂 Rails API Setup Guide

## 📋 Обзор

Это руководство описывает создание Rails API приложения для работы с данными IKEA парсера. Приложение будет использовать PostgreSQL, Fast JSON API (или OJ), Rails 8 и Ruby 3.3.0.

---

## 🎯 Технологический стек

- **Ruby**: 3.3.0 (через asdf)
- **Rails**: 8.0
- **База данных**: PostgreSQL
- **Кэш/Поиск**: Redis
- **Веб-сервер**: Passenger + Nginx
- **JSON Serializer**: Fast JSON API или OJ
- **API формат**: JSON

---

## 📦 Предварительные требования

### 1. Установка Ruby 3.3.0 через asdf

```bash
# Установка asdf
git clone https://github.com/asdf-vm/asdf.git ~/.asdf --branch v0.14.0
echo '. "$HOME/.asdf/asdf.sh"' >> ~/.bashrc
echo '. "$HOME/.asdf/completions/asdf.bash"' >> ~/.bashrc
source ~/.bashrc

# Установка плагина Ruby
asdf plugin add ruby https://github.com/asdf-vm/asdf-ruby.git

# Установка Ruby 3.3.0
asdf install ruby 3.3.0
asdf global ruby 3.3.0

# Проверка версии
ruby -v  # => ruby 3.3.0
```

### 2. Установка PostgreSQL

```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install postgresql postgresql-contrib libpq-dev

# Проверка
psql --version
```

### 3. Установка Redis

```bash
# Ubuntu/Debian
sudo apt-get install redis-server
sudo systemctl start redis-server
sudo systemctl enable redis-server

# Проверка
redis-cli ping  # => PONG
```

### 4. Установка Rails 8

```bash
gem install rails -v 8.0.0
rails -v  # => Rails 8.0.0
```

---

## 🏗️ Создание Rails API приложения

### 1. Создание нового проекта

```bash
rails new ikea_api \
  --api \
  --database=postgresql \
  --skip-test \
  --skip-system-test \
  --skip-action-mailer \
  --skip-action-mailbox \
  --skip-action-text \
  --skip-active-storage \
  --skip-action-cable

cd ikea_api
```

### 2. Добавление гемов в Gemfile

```ruby
# Gemfile

# Fast JSON API (альтернатива: gem 'oj')
gem 'fast_jsonapi'

# Или используйте OJ для быстрой сериализации
# gem 'oj'

# CORS для API
gem 'rack-cors'

# JWT для аутентификации
gem 'jwt'
gem 'bcrypt'

# Валидация и обработка ошибок
gem 'pry-rails'
gem 'annotate'

group :development, :test do
  gem 'rspec-rails'
  gem 'factory_bot_rails'
end
```

### 3. Установка зависимостей

```bash
bundle install
```

---

## 🗄️ Настройка базы данных

### 1. Конфигурация database.yml

```yaml
# config/database.yml

default: &default
  adapter: postgresql
  encoding: unicode
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
  timeout: 5000

development:
  <<: *default
  database: ikea_api_development
  username: postgres
  password: postgres
  host: localhost
  port: 5432

production:
  <<: *default
  database: ikea_api_production
  username: <%= ENV['DB_USERNAME'] %>
  password: <%= ENV['DB_PASSWORD'] %>
  host: <%= ENV['DB_HOST'] %>
  port: <%= ENV['DB_PORT'] || 5432 %>
```

### 2. Создание базы данных

```bash
rails db:create
rails db:migrate
```

---

## 📊 Создание моделей на основе DATA_SCHEMA.md

### 1. Модель Product

```bash
rails generate model Product \
  sku:string:uniq \
  unique_id:integer \
  item_no:string \
  url:string \
  name:string \
  name_ru:string \
  collection:string \
  variants:text \
  related_products:text \
  set_items:text \
  bundle_items:text \
  images:text \
  local_images:text \
  images_total:integer \
  images_stored:integer \
  images_incomplete:boolean \
  videos:text \
  manuals:text \
  price:decimal \
  quantity:integer \
  home_delivery:string \
  weight:decimal \
  net_weight:decimal \
  package_volume:decimal \
  package_dimensions:string \
  dimensions:string \
  is_parcel:boolean \
  content:text \
  content_ru:text \
  material_info:text \
  material_info_ru:text \
  good_info:text \
  good_info_ru:text \
  translated:boolean \
  is_bestseller:boolean \
  is_popular:boolean \
  category_id:string \
  delivery_type:string \
  delivery_name:string \
  delivery_cost:decimal \
  delivery_reason:string
```

### 2. Модель Category

```bash
rails generate model Category \
  ikea_id:string:uniq \
  unique_id:integer \
  name:string \
  translated_name:string \
  url:string \
  remote_image_url:string \
  local_image_path:string \
  parent_ids:text \
  is_deleted:boolean \
  is_important:boolean \
  is_popular:boolean
```

### 3. Модель Filter

```bash
rails generate model Filter \
  parameter:string:uniq \
  name:string \
  name_ru:string
```

### 4. Модель FilterValue

```bash
rails generate model FilterValue \
  filter:references \
  value_id:string:uniq \
  name:string \
  name_ru:string \
  hex:string
```

### 5. Модель User

```bash
rails generate model User \
  username:string:uniq \
  email:string \
  password_digest:string \
  role:string \
  is_active:boolean
```

### 6. Модель Delivery (опционально)

```bash
rails generate model Delivery \
  weight:decimal \
  delivery_type:string \
  is_ikea_family:boolean \
  order_value:decimal \
  is_weekend:boolean
```

### 7. Применение миграций

```bash
rails db:migrate
```

---

## 🔧 Настройка моделей

### 1. Product Model

```ruby
# app/models/product.rb

class Product < ApplicationRecord
  # Валидации
  validates :sku, presence: true, uniqueness: true
  validates :name, presence: true
  
  # Ассоциации
  belongs_to :category, foreign_key: :category_id, primary_key: :ikea_id, optional: true
  has_many :product_filter_values
  has_many :filter_values, through: :product_filter_values
  
  # Scopes
  scope :bestsellers, -> { where(is_bestseller: true) }
  scope :popular, -> { where(is_popular: true) }
  scope :with_category, -> { where.not(category_id: nil) }
  
  # Сериализация массивов
  serialize :variants, Array
  serialize :related_products, Array
  serialize :set_items, Array
  serialize :bundle_items, Array
  serialize :images, Array
  serialize :local_images, Array
  serialize :videos, Array
  serialize :manuals, Array
  
  # Callbacks
  before_save :calculate_delivery, if: :weight_changed?
  
  private
  
  def calculate_delivery
    # Логика расчета доставки
    # Аналогично deliveryService.js
  end
end
```

### 2. Category Model

```ruby
# app/models/category.rb

class Category < ApplicationRecord
  self.primary_key = 'ikea_id'
  
  validates :ikea_id, presence: true, uniqueness: true
  validates :name, presence: true
  
  has_many :products, foreign_key: :category_id, primary_key: :ikea_id
  
  serialize :parent_ids, Array
  
  scope :popular, -> { where(is_popular: true) }
  scope :active, -> { where(is_deleted: false) }
end
```

### 3. Filter Model

```ruby
# app/models/filter.rb

class Filter < ApplicationRecord
  validates :parameter, presence: true, uniqueness: true
  
  has_many :filter_values
end
```

### 4. FilterValue Model

```ruby
# app/models/filter_value.rb

class FilterValue < ApplicationRecord
  validates :value_id, presence: true, uniqueness: true
  
  belongs_to :filter
  has_many :product_filter_values
  has_many :products, through: :product_filter_values
end
```

### 5. User Model

```ruby
# app/models/user.rb

class User < ApplicationRecord
  has_secure_password
  
  validates :username, presence: true, uniqueness: true
  validates :email, uniqueness: true, allow_nil: true
  validates :role, inclusion: { in: %w[user admin] }
  
  scope :active, -> { where(is_active: true) }
end
```

---

## 🎨 JSON Serializers (Fast JSON API)

### 1. Product Serializer

```ruby
# app/serializers/product_serializer.rb

class ProductSerializer
  include FastJsonapi::ObjectSerializer
  
  attributes :sku, :unique_id, :item_no, :url, :name, :name_ru,
             :collection, :price, :quantity, :weight, :net_weight,
             :package_volume, :package_dimensions, :dimensions,
             :is_parcel, :is_bestseller, :is_popular, :category_id,
             :delivery_type, :delivery_name, :delivery_cost,
             :delivery_reason, :created_at, :updated_at
  
  attribute :variants do |product|
    product.variants || []
  end
  
  attribute :images do |product|
    product.images || []
  end
  
  attribute :local_images do |product|
    product.local_images || []
  end
  
  belongs_to :category, serializer: CategorySerializer, if: Proc.new { |record| record.category.present? }
  
  attribute :category_name do |product|
    product.category&.translated_name || product.category&.name || ''
  end
end
```

### 2. Category Serializer

```ruby
# app/serializers/category_serializer.rb

class CategorySerializer
  include FastJsonapi::ObjectSerializer
  
  set_id :ikea_id
  
  attributes :ikea_id, :unique_id, :name, :translated_name, :url,
             :remote_image_url, :local_image_path, :is_deleted,
             :is_important, :is_popular, :created_at, :updated_at
  
  attribute :parent_ids do |category|
    category.parent_ids || []
  end
  
  has_many :products, serializer: ProductSerializer
end
```

---

## 🛣️ API Routes

### 1. Настройка routes.rb

```ruby
# config/routes.rb

Rails.application.routes.draw do
  namespace :api do
    namespace :v1 do
      # Products
      resources :products, only: [:index, :show] do
        collection do
          get :bestsellers
          get :popular
        end
      end
      
      # Categories
      resources :categories, only: [:index, :show] do
        collection do
          get :popular
          get :tree
        end
      end
      
      # Filters
      resources :filters, only: [:index]
      
      # Delivery
      resources :delivery, only: [] do
        collection do
          get :types
          post :calculate
        end
      end
      
      # Auth
      post 'auth/login', to: 'auth#login'
      post 'auth/register', to: 'auth#register'
    end
  end
end
```

### 2. Products Controller

```ruby
# app/controllers/api/v1/products_controller.rb

module Api
  module V1
    class ProductsController < ApplicationController
      before_action :authenticate_user, except: [:index, :show, :bestsellers, :popular]
      
      def index
        products = Product.includes(:category)
                         .page(params[:page])
                         .per(params[:per_page] || 50)
        
        render json: ProductSerializer.new(products, {
          include: [:category],
          meta: {
            total: products.total_count,
            page: params[:page] || 1,
            per_page: params[:per_page] || 50
          }
        })
      end
      
      def show
        product = Product.find_by(sku: params[:id])
        render json: ProductSerializer.new(product, include: [:category])
      end
      
      def bestsellers
        products = Product.bestsellers
                         .includes(:category)
                         .page(params[:page])
                         .per(params[:per_page] || 10)
        
        render json: ProductSerializer.new(products, {
          include: [:category],
          meta: {
            total: products.total_count,
            page: params[:page] || 1
          }
        })
      end
      
      def popular
        products = Product.popular
                         .includes(:category)
                         .page(params[:page])
                         .per(params[:per_page] || 10)
        
        render json: ProductSerializer.new(products, {
          include: [:category],
          meta: {
            total: products.total_count,
            page: params[:page] || 1
          }
        })
      end
    end
  end
end
```

---

## 🔐 Аутентификация (JWT)

### 1. JWT Service

```ruby
# app/services/jwt_service.rb

class JwtService
  SECRET_KEY = Rails.application.credentials.secret_key_base
  
  def self.encode(payload, exp = 24.hours.from_now)
    payload[:exp] = exp.to_i
    JWT.encode(payload, SECRET_KEY)
  end
  
  def self.decode(token)
    decoded = JWT.decode(token, SECRET_KEY)[0]
    HashWithIndifferentAccess.new(decoded)
  rescue JWT::DecodeError => e
    nil
  end
end
```

### 2. Auth Controller

```ruby
# app/controllers/api/v1/auth_controller.rb

module Api
  module V1
    class AuthController < ApplicationController
      def login
        user = User.find_by(username: params[:username])
        
        if user&.authenticate(params[:password]) && user.is_active?
          token = JwtService.encode({ user_id: user.id })
          render json: {
            token: token,
            user: {
              id: user.id,
              username: user.username,
              role: user.role
            }
          }
        else
          render json: { error: 'Неверные учетные данные' }, status: :unauthorized
        end
      end
      
      def register
        user = User.new(user_params)
        
        if user.save
          token = JwtService.encode({ user_id: user.id })
          render json: {
            token: token,
            user: {
              id: user.id,
              username: user.username,
              role: user.role
            }
          }, status: :created
        else
          render json: { errors: user.errors.full_messages }, status: :unprocessable_entity
        end
      end
      
      private
      
      def user_params
        params.require(:user).permit(:username, :email, :password, :password_confirmation)
      end
    end
  end
end
```

### 3. Application Controller

```ruby
# app/controllers/application_controller.rb

class ApplicationController < ActionController::API
  include ActionController::HttpAuthentication::Token::ControllerMethods
  
  def authenticate_user
    token = request.headers['Authorization']&.split(' ')&.last
    
    if token
      decoded = JwtService.decode(token)
      @current_user = User.find(decoded[:user_id]) if decoded
    end
    
    render json: { error: 'Не авторизован' }, status: :unauthorized unless @current_user
  end
  
  def current_user
    @current_user
  end
end
```

---

## 🌐 CORS настройка

```ruby
# config/initializers/cors.rb

Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins '*'
    
    resource '*',
      headers: :any,
      methods: [:get, :post, :put, :patch, :delete, :options, :head]
  end
end
```

---

## 🔴 Настройка Redis

### 1. Конфигурация Redis в application.rb

```ruby
# config/application.rb

module IkeaApi
  class Application < Rails::Application
    # ... существующие настройки ...
    
    # Redis для кэширования
    config.cache_store = :redis_cache_store, {
      url: ENV['REDIS_URL'] || 'redis://localhost:6379/0',
      password: ENV['REDIS_PASSWORD'],
      namespace: 'ikea_api',
      expires_in: 1.hour
    }
  end
end
```

### 2. Переменные окружения

```env
# .env
REDIS_URL=redis://localhost:6379/0
REDIS_PASSWORD=your_redis_password  # Опционально
```

### 3. Использование Redis для поиска

```ruby
# app/services/search_service.rb

class SearchService
  def self.search(query, page: 1, per_page: 20)
    cache_key = "search:#{query.downcase}:#{page}:#{per_page}"
    
    Rails.cache.fetch(cache_key, expires_in: 1.hour) do
      Product.where("name ILIKE ? OR name_ru ILIKE ?", 
                    "%#{query}%", "%#{query}%")
            .page(page)
            .per(per_page)
            .to_a
    end
  end
  
  def self.clear_search_cache
    Rails.cache.delete_matched("search:*")
  end
end
```

### 4. Использование в контроллере

```ruby
# app/controllers/api/v1/products_controller.rb

module Api
  module V1
    class ProductsController < ApplicationController
      def search
        query = params[:q]
        page = params[:page] || 1
        
        products = SearchService.search(query, page: page, per_page: 20)
        
        render json: ProductSerializer.new(products, {
          meta: {
            query: query,
            page: page,
            total: products.count
          }
        })
      end
    end
  end
end
```

### 5. Добавление маршрута для поиска

```ruby
# config/routes.rb

Rails.application.routes.draw do
  namespace :api do
    namespace :v1 do
      resources :products, only: [:index, :show] do
        collection do
          get :search
          get :bestsellers
          get :popular
        end
      end
      # ... остальные маршруты
    end
  end
end
```

---

## 📝 Индексы базы данных

### Добавление индексов через миграции

```ruby
# db/migrate/xxxxxx_add_indexes.rb

class AddIndexes < ActiveRecord::Migration[8.0]
  def change
    # Products
    add_index :products, :sku, unique: true
    add_index :products, :unique_id, unique: true, where: "unique_id IS NOT NULL"
    add_index :products, :category_id
    add_index :products, :is_bestseller
    add_index :products, :is_popular
    add_index :products, :updated_at
    
    # Categories
    add_index :categories, :ikea_id, unique: true
    add_index :categories, :unique_id, unique: true, where: "unique_id IS NOT NULL"
    add_index :categories, :is_popular
    
    # Filters
    add_index :filters, :parameter, unique: true
    
    # FilterValues
    add_index :filter_values, :value_id, unique: true
    add_index :filter_values, :filter_id
    
    # Users
    add_index :users, :username, unique: true
    add_index :users, :email, unique: true, where: "email IS NOT NULL"
  end
end
```

---

## 🚀 Запуск приложения

```bash
# Development
rails server

# Production (с Passenger + Nginx)
# См. RAILS_DEPLOYMENT.md для деталей развертывания
RAILS_ENV=production rails server
```

---

## 📚 Дополнительные ресурсы

- [Rails API Documentation](https://guides.rubyonrails.org/api_app.html)
- [Fast JSON API](https://github.com/fast-jsonapi/fast_jsonapi)
- [PostgreSQL Documentation](https://www.postgresql.org/docs/)
- [Redis Documentation](https://redis.io/docs/)
- [Passenger Documentation](https://www.phusionpassenger.com/docs/)
- [asdf Documentation](https://asdf-vm.com/)
- [JWT Ruby Gem](https://github.com/jwt/ruby-jwt)

---

## 🔄 Синхронизация данных из MongoDB в PostgreSQL

Для синхронизации данных из MongoDB в PostgreSQL используется воркер, который отслеживает изменения в реальном времени через MongoDB Change Streams.

### 1. Добавление гемов в Gemfile

```ruby
# Gemfile
gem 'mongo', '~> 2.18'
gem 'sidekiq', '~> 7.0'
gem 'sidekiq-cron', '~> 1.10'  # Для периодических задач
```

### 2. Конфигурация MongoDB

```ruby
# config/initializers/mongodb.rb

require 'mongo'

module MongodbSync
  def self.client
    @client ||= begin
      uri = ENV['MONGODB_URI'] || 'mongodb://localhost:27017/ikea'
      Mongo::Client.new(uri)
    end
  end

  def self.products_collection
    client[:products]
  end

  def self.categories_collection
    client[:categories]
  end

  def self.filters_collection
    client[:filters]
  end

  def self.filter_values_collection
    client[:filtervalues]
  end
end
```

### 3. Сервис для синхронизации продуктов

```ruby
# app/services/mongodb_sync/product_sync_service.rb

module MongodbSync
  class ProductSyncService
    def self.sync_product(mongo_doc)
      product = Product.find_or_initialize_by(sku: mongo_doc['sku'])
      
      # Маппинг полей из MongoDB в PostgreSQL
      product.assign_attributes(
        unique_id: mongo_doc['uniqueId'],
        item_no: mongo_doc['itemNo'],
        url: mongo_doc['url'],
        name: mongo_doc['name'],
        name_ru: mongo_doc['nameRu'],
        collection: mongo_doc['collection'],
        variants: mongo_doc['variants'] || [],
        related_products: mongo_doc['relatedProducts'] || [],
        set_items: mongo_doc['setItems'] || [],
        bundle_items: mongo_doc['bundleItems'] || [],
        images: mongo_doc['images'] || [],
        local_images: mongo_doc['localImages'] || [],
        images_total: mongo_doc['imagesTotal'] || 0,
        images_stored: mongo_doc['imagesStored'] || 0,
        images_incomplete: mongo_doc['imagesIncomplete'] || false,
        videos: mongo_doc['videos'] || [],
        manuals: mongo_doc['manuals'] || [],
        price: mongo_doc['price'] || 0,
        quantity: mongo_doc['quantity'] || 0,
        home_delivery: mongo_doc['homeDelivery'],
        weight: mongo_doc['weight'] || 0,
        net_weight: mongo_doc['netWeight'] || 0,
        package_volume: mongo_doc['packageVolume'] || 0,
        package_dimensions: mongo_doc['packageDimensions'],
        dimensions: mongo_doc['dimensions'],
        is_parcel: mongo_doc['isParcel'] || false,
        content: mongo_doc['content'],
        content_ru: mongo_doc['contentRu'],
        material_info: mongo_doc['materialInfo'],
        material_info_ru: mongo_doc['materialInfoRu'],
        good_info: mongo_doc['goodInfo'],
        good_info_ru: mongo_doc['goodInfoRu'],
        translated: mongo_doc['translated'] || false,
        is_bestseller: mongo_doc['isBestseller'] || false,
        is_popular: mongo_doc['isPopular'] || false,
        category_id: mongo_doc['categoryId'],
        delivery_type: mongo_doc['deliveryType'],
        delivery_name: mongo_doc['deliveryName'],
        delivery_cost: mongo_doc['deliveryCost'] || 0,
        delivery_reason: mongo_doc['deliveryReason']
      )
      
      product.save!
      product
    rescue => e
      Rails.logger.error "Error syncing product #{mongo_doc['sku']}: #{e.message}"
      raise
    end

    def self.delete_product(sku)
      product = Product.find_by(sku: sku)
      product&.destroy
    end
  end
end
```

### 4. Сервис для синхронизации категорий

```ruby
# app/services/mongodb_sync/category_sync_service.rb

module MongodbSync
  class CategorySyncService
    def self.sync_category(mongo_doc)
      category = Category.find_or_initialize_by(ikea_id: mongo_doc['id'])
      
      category.assign_attributes(
        unique_id: mongo_doc['uniqueId'],
        name: mongo_doc['name'],
        translated_name: mongo_doc['translatedName'],
        url: mongo_doc['url'],
        remote_image_url: mongo_doc['remoteImageUrl'],
        local_image_path: mongo_doc['localImagePath'],
        parent_ids: mongo_doc['parentIds'] || [],
        is_deleted: mongo_doc['isDeleted'] || false,
        is_important: mongo_doc['isImportant'] || false,
        is_popular: mongo_doc['isPopular'] || false
      )
      
      category.save!
      category
    rescue => e
      Rails.logger.error "Error syncing category #{mongo_doc['id']}: #{e.message}"
      raise
    end

    def self.delete_category(ikea_id)
      category = Category.find_by(ikea_id: ikea_id)
      category&.destroy
    end
  end
end
```

### 5. Sidekiq воркер для обработки изменений

```ruby
# app/workers/mongodb_sync_worker.rb

class MongodbSyncWorker
  include Sidekiq::Worker
  
  sidekiq_options queue: :mongodb_sync, retry: 3, backtrace: true

  def perform(collection_name, operation, document_id, full_document = nil)
    case collection_name
    when 'products'
      handle_product_change(operation, document_id, full_document)
    when 'categories'
      handle_category_change(operation, document_id, full_document)
    when 'filters'
      handle_filter_change(operation, document_id, full_document)
    when 'filtervalues'
      handle_filter_value_change(operation, document_id, full_document)
    else
      Rails.logger.warn "Unknown collection: #{collection_name}"
    end
  end

  private

  def handle_product_change(operation, document_id, full_document)
    case operation
    when 'insert', 'update', 'replace'
      if full_document
        MongodbSync::ProductSyncService.sync_product(full_document)
        Rails.logger.info "Synced product: #{full_document['sku']}"
      else
        # Если полный документ не передан, получаем его из MongoDB
        mongo_doc = MongodbSync.products_collection.find(_id: BSON::ObjectId(document_id)).first
        MongodbSync::ProductSyncService.sync_product(mongo_doc) if mongo_doc
      end
    when 'delete'
      # Для удаления нужен sku, получаем из MongoDB перед удалением
      mongo_doc = MongodbSync.products_collection.find(_id: BSON::ObjectId(document_id)).first
      MongodbSync::ProductSyncService.delete_product(mongo_doc['sku']) if mongo_doc
      Rails.logger.info "Deleted product: #{mongo_doc['sku']}" if mongo_doc
    end
  rescue => e
    Rails.logger.error "Error handling product change: #{e.message}"
    raise
  end

  def handle_category_change(operation, document_id, full_document)
    case operation
    when 'insert', 'update', 'replace'
      if full_document
        MongodbSync::CategorySyncService.sync_category(full_document)
        Rails.logger.info "Synced category: #{full_document['id']}"
      else
        mongo_doc = MongodbSync.categories_collection.find(_id: BSON::ObjectId(document_id)).first
        MongodbSync::CategorySyncService.sync_category(mongo_doc) if mongo_doc
      end
    when 'delete'
      mongo_doc = MongodbSync.categories_collection.find(_id: BSON::ObjectId(document_id)).first
      MongodbSync::CategorySyncService.delete_category(mongo_doc['id']) if mongo_doc
      Rails.logger.info "Deleted category: #{mongo_doc['id']}" if mongo_doc
    end
  rescue => e
    Rails.logger.error "Error handling category change: #{e.message}"
    raise
  end

  def handle_filter_change(operation, document_id, full_document)
    # Реализация синхронизации фильтров
    Rails.logger.info "Filter change: #{operation} - #{document_id}"
  end

  def handle_filter_value_change(operation, document_id, full_document)
    # Реализация синхронизации значений фильтров
    Rails.logger.info "FilterValue change: #{operation} - #{document_id}"
  end
end
```

### 6. Процесс отслеживания изменений (Change Streams)

```ruby
# app/services/mongodb_sync/change_stream_listener.rb

module MongodbSync
  class ChangeStreamListener
    def self.start
      Thread.new do
        begin
          Rails.logger.info "Starting MongoDB Change Streams listener..."
          
          # Отслеживание изменений в коллекции products
          products_stream = products_collection.watch(
            [
              { '$match' => { 'operationType' => { '$in' => ['insert', 'update', 'replace', 'delete'] } } }
            ],
            full_document: 'updateLookup'
          )
          
          # Отслеживание изменений в коллекции categories
          categories_stream = categories_collection.watch(
            [
              { '$match' => { 'operationType' => { '$in' => ['insert', 'update', 'replace', 'delete'] } } }
            ],
            full_document: 'updateLookup'
          )
          
          # Обработка изменений products
          Thread.new do
            products_stream.each do |change|
              handle_change('products', change)
            end
          end
          
          # Обработка изменений categories
          Thread.new do
            categories_stream.each do |change|
              handle_change('categories', change)
            end
          end
          
        rescue => e
          Rails.logger.error "Error in Change Stream listener: #{e.message}"
          Rails.logger.error e.backtrace.join("\n")
          sleep 5
          retry
        end
      end
    end

    private

    def self.handle_change(collection_name, change)
      operation = change['operationType']
      document_id = change['documentKey']['_id']
      full_document = change['fullDocument']
      
      # Добавляем задачу в Sidekiq
      MongodbSyncWorker.perform_async(
        collection_name,
        operation,
        document_id.to_s,
        full_document
      )
      
      Rails.logger.debug "Queued #{operation} for #{collection_name}: #{document_id}"
    rescue => e
      Rails.logger.error "Error handling change: #{e.message}"
    end

    def self.products_collection
      MongodbSync.products_collection
    end

    def self.categories_collection
      MongodbSync.categories_collection
    end
  end
end
```

### 7. Инициализация при запуске приложения

```ruby
# config/initializers/mongodb_sync.rb

if Rails.env.production? || Rails.env.staging?
  Rails.application.config.after_initialize do
    # Запуск слушателя изменений только в production/staging
    MongodbSync::ChangeStreamListener.start
    
    Rails.logger.info "MongoDB Change Streams listener started"
  end
end
```

### 8. Начальная синхронизация (одноразовая задача)

```ruby
# lib/tasks/mongodb_sync.rake

namespace :mongodb do
  desc "Initial sync from MongoDB to PostgreSQL"
  task initial_sync: :environment do
    puts "Starting initial sync from MongoDB..."
    
    # Синхронизация продуктов
    puts "Syncing products..."
    count = 0
    MongodbSync.products_collection.find.each do |product|
      MongodbSync::ProductSyncService.sync_product(product)
      count += 1
      print "." if count % 100 == 0
    end
    puts "\nSynced #{count} products"
    
    # Синхронизация категорий
    puts "Syncing categories..."
    count = 0
    MongodbSync.categories_collection.find.each do |category|
      MongodbSync::CategorySyncService.sync_category(category)
      count += 1
    end
    puts "Synced #{count} categories"
    
    puts "Initial sync completed!"
  end

  desc "Start MongoDB change stream listener"
  task start_listener: :environment do
    MongodbSync::ChangeStreamListener.start
    puts "MongoDB Change Streams listener started. Press Ctrl+C to stop."
    sleep
  end
end
```

### 9. Конфигурация Sidekiq

```ruby
# config/initializers/sidekiq.rb

Sidekiq.configure_server do |config|
  config.redis = { url: ENV['REDIS_URL'] || 'redis://localhost:6379/0' }
end

Sidekiq.configure_client do |config|
  config.redis = { url: ENV['REDIS_URL'] || 'redis://localhost:6379/0' }
end
```

### 10. Переменные окружения

```env
# .env
MONGODB_URI=mongodb://ikea_user:password@localhost:27017/ikea?authSource=ikea
REDIS_URL=redis://localhost:6379/0
```

### 11. Запуск воркера

```bash
# Запуск Sidekiq воркера
bundle exec sidekiq -q mongodb_sync

# Или через systemd (см. RAILS_DEPLOYMENT.md)
```

### 12. Мониторинг

```ruby
# config/routes.rb (для веб-интерфейса Sidekiq)

require 'sidekiq/web'

Rails.application.routes.draw do
  mount Sidekiq::Web => '/sidekiq'  # Защитите этот маршрут авторизацией!
  # ... остальные маршруты
end
```

### 13. Обработка ошибок и retry

Воркер автоматически повторяет неудачные задачи до 3 раз (настраивается в `sidekiq_options`). Для более сложной логики retry можно использовать:

```ruby
# app/workers/mongodb_sync_worker.rb

sidekiq_options retry: 3, backtrace: true

def perform(collection_name, operation, document_id, full_document = nil)
  # ... код синхронизации
rescue => e
  Rails.logger.error "Sync error: #{e.message}"
  # Кастомная логика обработки ошибок
  raise
end
```

---

**Примечание**: 
- Change Streams требуют MongoDB 3.6+ и replica set (даже для одного сервера)
- Для production рекомендуется настроить replica set
- Воркер автоматически обрабатывает все изменения: insert, update, replace, delete
- Начальная синхронизация выполняется один раз через rake task

---

## 🚢 Развертывание с Kamal

Kamal (ранее MRSK) - это современный инструмент для развертывания Rails приложений с использованием Docker.

### 1. Установка Kamal

```bash
gem install kamal
kamal version
```

### 2. Инициализация Kamal

```bash
kamal setup
```

Это создаст файл `config/deploy.yml` и `.kamal/secrets` для хранения секретов.

### 3. Конфигурация deploy.yml

```yaml
# config/deploy.yml

service: ikea_api
image: your-registry/ikea_api

servers:
  web:
    hosts:
      - your-server-ip
    options:
      healthcheck:
        path: /up
        port: 3000

registry:
  username: your-registry-username
  password:
    - KAMAL_REGISTRY_PASSWORD

builder:
  context: .
  dockerfile: Dockerfile

env:
  secret:
    - RAILS_MASTER_KEY
    - DB_USERNAME
    - DB_PASSWORD
    - DB_HOST
    - REDIS_URL
    - MONGODB_URI
    - JWT_SECRET

volumes:
  - storage:/rails/storage

accessories:
  postgres:
    image: postgres:16
    host: your-server-ip
    port: 5432
    env:
      secret:
        - POSTGRES_PASSWORD
    directories:
      - postgres-data:/var/lib/postgresql/data
    options:
      healthcheck:
        test: pg_isready -U postgres
        interval: 10s
        timeout: 5s
        retries: 5

  redis:
    image: redis:7-alpine
    host: your-server-ip
    port: 6379
    directories:
      - redis-data:/data
    options:
      healthcheck:
        test: redis-cli ping
        interval: 10s
        timeout: 5s
        retries: 5

  sidekiq:
    image: your-registry/ikea_api
    host: your-server-ip
    cmd: bundle exec sidekiq -q mongodb_sync
    env:
      secret:
        - RAILS_MASTER_KEY
        - DB_USERNAME
        - DB_PASSWORD
        - DB_HOST
        - REDIS_URL
        - MONGODB_URI
```

### 4. Создание Dockerfile

```dockerfile
# Dockerfile

FROM ruby:3.3.0

WORKDIR /rails

# Установка зависимостей системы
RUN apt-get update -qq && \
    apt-get install -y build-essential libpq-dev nodejs && \
    rm -rf /var/lib/apt/lists/*

# Установка гемов
COPY Gemfile Gemfile.lock ./
RUN bundle install

# Копирование кода приложения
COPY . .

# Предкомпиляция assets (если есть)
# RUN bundle exec rails assets:precompile

EXPOSE 3000

CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0"]
```

### 5. Создание .dockerignore

```
.dockerignore
.git
.gitignore
.env
.env.*
log/*
tmp/*
node_modules
coverage
.sass-cache
```

### 6. Настройка секретов

```bash
# .kamal/secrets (не коммитить в git!)
RAILS_MASTER_KEY=your_master_key_here
DB_USERNAME=postgres
DB_PASSWORD=your_db_password
DB_HOST=postgres
REDIS_URL=redis://redis:6379/0
MONGODB_URI=mongodb://user:password@mongodb-host:27017/ikea
JWT_SECRET=your_jwt_secret
POSTGRES_PASSWORD=your_postgres_password
```

### 7. Команды Kamal

```bash
# Сборка и развертывание
kamal deploy

# Просмотр логов
kamal app logs

# Выполнение команд на сервере
kamal app exec "rails console"

# Выполнение rake задач
kamal app exec "rails db:migrate"

# Остановка приложения
kamal app stop

# Запуск приложения
kamal app start

# Перезапуск приложения
kamal app restart

# Просмотр конфигурации
kamal config

# Просмотр версии образа
kamal app version
```

### 8. Переменные окружения для production

```bash
# На сервере в .kamal/secrets
RAILS_ENV=production
RAILS_MASTER_KEY=your_master_key
DB_USERNAME=postgres
DB_PASSWORD=secure_password
DB_HOST=postgres
DB_PORT=5432
REDIS_URL=redis://redis:6379/0
MONGODB_URI=mongodb://user:password@mongodb-host:27017/ikea?authSource=ikea
JWT_SECRET=your_jwt_secret_key
```

### 9. Healthcheck endpoint

```ruby
# config/routes.rb
Rails.application.routes.draw do
  get '/up', to: 'health#check'
  # ... остальные маршруты
end

# app/controllers/health_controller.rb
class HealthController < ApplicationController
  def check
    render json: { status: 'ok', timestamp: Time.current }
  end
end
```

### 10. Первое развертывание

```bash
# 1. Убедитесь, что Docker установлен на сервере
# 2. Настройте доступ к registry (Docker Hub, GitHub Container Registry и т.д.)
# 3. Настройте SSH доступ к серверу
# 4. Запустите развертывание
kamal deploy

# 5. Выполните миграции
kamal app exec "rails db:migrate"

# 6. Создайте начальные данные (если нужно)
kamal app exec "rails db:seed"
```

### 11. Обновление приложения

```bash
# После изменений в коде
git commit -am "Update application"
git push

# Развертывание
kamal deploy

# Если нужны миграции
kamal app exec "rails db:migrate"
```

### 12. Мониторинг и логи

```bash
# Логи приложения
kamal app logs -f

# Логи Sidekiq
kamal accessory logs sidekiq -f

# Логи PostgreSQL
kamal accessory logs postgres -f

# Логи Redis
kamal accessory logs redis -f
```

---

## 📖 API Документация (Swagger/OpenAPI)

Для автоматической генерации документации API используется rswag.

### 1. Добавление гемов в Gemfile

```ruby
# Gemfile

group :development, :test do
  gem 'rswag'
  gem 'rswag-api'
  gem 'rswag-ui'
end
```

### 2. Установка зависимостей

```bash
bundle install
rails generate rswag:install
```

### 3. Конфигурация Swagger

```ruby
# config/initializers/rswag_api.rb

Rswag::Api.configure do |c|
  c.swagger_root = Rails.root.join('swagger').to_s
  c.swagger_filter = nil
end

# config/initializers/rswag_ui.rb

Rswag::Ui.configure do |c|
  c.swagger_endpoint '/api-docs/v1/swagger.yaml', 'API V1 Docs'
  c.basic_auth_enabled = false
end
```

### 4. Настройка маршрутов

```ruby
# config/routes.rb

Rails.application.routes.draw do
  mount Rswag::Api::Engine => '/api-docs'
  mount Rswag::Ui::Engine => '/api-docs'
  
  namespace :api do
    namespace :v1 do
      # ... ваши маршруты
    end
  end
end
```

### 5. Создание Swagger спецификации

```ruby
# swagger/v1/swagger.yaml

openapi: '3.0.1'
info:
  title: IKEA API
  version: v1
  description: |
    API для работы с данными IKEA парсера.
    
    ## Аутентификация
    Большинство endpoints требуют JWT токен в заголовке:
    ```
    Authorization: Bearer <token>
    ```
    
    Получить токен можно через `/api/v1/auth/login`

servers:
  - url: http://localhost:3000
    description: Development server
  - url: https://api.ikeya.by
    description: Production server

paths:
  /api/v1/products:
    get:
      summary: Список товаров
      tags:
        - Products
      parameters:
        - name: page
          in: query
          schema:
            type: integer
            default: 1
        - name: per_page
          in: query
          schema:
            type: integer
            default: 50
        - name: category_id
          in: query
          schema:
            type: string
        - name: is_bestseller
          in: query
          schema:
            type: boolean
        - name: is_popular
          in: query
            type: boolean
      responses:
        '200':
          description: Список товаров
          content:
            application/json:
              schema:
                type: object
                properties:
                  data:
                    type: array
                    items:
                      $ref: '#/components/schemas/Product'
                  meta:
                    $ref: '#/components/schemas/Meta'

  /api/v1/products/{id}:
    get:
      summary: Получить товар по SKU
      tags:
        - Products
      parameters:
        - name: id
          in: path
          required: true
          schema:
            type: string
      responses:
        '200':
          description: Данные товара
          content:
            application/json:
              schema:
                type: object
                properties:
                  data:
                    $ref: '#/components/schemas/Product'
        '404':
          description: Товар не найден

  /api/v1/products/bestsellers:
    get:
      summary: Хиты продаж
      tags:
        - Products
      parameters:
        - name: page
          in: query
          schema:
            type: integer
            default: 1
        - name: per_page
          in: query
          schema:
            type: integer
            default: 10
      responses:
        '200':
          description: Список хитов продаж
          content:
            application/json:
              schema:
                type: object
                properties:
                  data:
                    type: array
                    items:
                      $ref: '#/components/schemas/Product'

  /api/v1/products/popular:
    get:
      summary: Популярные товары
      tags:
        - Products
      parameters:
        - name: page
          in: query
          schema:
            type: integer
            default: 1
        - name: per_page
          in: query
          schema:
            type: integer
            default: 10
      responses:
        '200':
          description: Список популярных товаров
          content:
            application/json:
              schema:
                type: object
                properties:
                  data:
                    type: array
                    items:
                      $ref: '#/components/schemas/Product'

  /api/v1/categories:
    get:
      summary: Список категорий
      tags:
        - Categories
      parameters:
        - name: is_popular
          in: query
          schema:
            type: boolean
      responses:
        '200':
          description: Список категорий
          content:
            application/json:
              schema:
                type: object
                properties:
                  data:
                    type: array
                    items:
                      $ref: '#/components/schemas/Category'

  /api/v1/categories/{id}:
    get:
      summary: Получить категорию по ID
      tags:
        - Categories
      parameters:
        - name: id
          in: path
          required: true
          schema:
            type: string
      responses:
        '200':
          description: Данные категории
          content:
            application/json:
              schema:
                type: object
                properties:
                  data:
                    $ref: '#/components/schemas/Category'

  /api/v1/categories/popular:
    get:
      summary: Популярные категории
      tags:
        - Categories
      responses:
        '200':
          description: Список популярных категорий
          content:
            application/json:
              schema:
                type: object
                properties:
                  data:
                    type: array
                    items:
                      $ref: '#/components/schemas/Category'

  /api/v1/categories/tree:
    get:
      summary: Дерево категорий
      tags:
        - Categories
      responses:
        '200':
          description: Иерархическое дерево категорий
          content:
            application/json:
              schema:
                type: object
                properties:
                  data:
                    type: array
                    items:
                      $ref: '#/components/schemas/CategoryTree'

  /api/v1/auth/login:
    post:
      summary: Вход в систему
      tags:
        - Authentication
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              required:
                - username
                - password
              properties:
                username:
                  type: string
                password:
                  type: string
      responses:
        '200':
          description: Успешный вход
          content:
            application/json:
              schema:
                type: object
                properties:
                  token:
                    type: string
                  user:
                    $ref: '#/components/schemas/User'
        '401':
          description: Неверные учетные данные

  /api/v1/auth/register:
    post:
      summary: Регистрация
      tags:
        - Authentication
      requestBody:
        required: true
        content:
          application/json:
            schema:
              type: object
              required:
                - username
                - password
              properties:
                username:
                  type: string
                email:
                  type: string
                password:
                  type: string
                password_confirmation:
                  type: string
      responses:
        '201':
          description: Пользователь создан
          content:
            application/json:
              schema:
                type: object
                properties:
                  token:
                    type: string
                  user:
                    $ref: '#/components/schemas/User'
        '422':
          description: Ошибка валидации

components:
  schemas:
    Product:
      type: object
      properties:
        id:
          type: string
        type: string
        attributes:
          type: object
          properties:
            sku:
              type: string
            unique_id:
              type: integer
            item_no:
              type: string
            url:
              type: string
            name:
              type: string
            name_ru:
              type: string
            collection:
              type: string
            price:
              type: number
            quantity:
              type: integer
            weight:
              type: number
            net_weight:
              type: number
            package_volume:
              type: number
            package_dimensions:
              type: string
            dimensions:
              type: string
            is_parcel:
              type: boolean
            is_bestseller:
              type: boolean
            is_popular:
              type: boolean
            category_id:
              type: string
            delivery_type:
              type: string
            delivery_name:
              type: string
            delivery_cost:
              type: number
            delivery_reason:
              type: string
            variants:
              type: array
              items:
                type: string
            images:
              type: array
              items:
                type: string
            local_images:
              type: array
              items:
                type: string
            created_at:
              type: string
              format: date-time
            updated_at:
              type: string
              format: date-time

    Category:
      type: object
      properties:
        id:
          type: string
        type: string
        attributes:
          type: object
          properties:
            ikea_id:
              type: string
            unique_id:
              type: integer
            name:
              type: string
            translated_name:
              type: string
            url:
              type: string
            remote_image_url:
              type: string
            local_image_path:
              type: string
            is_deleted:
              type: boolean
            is_important:
              type: boolean
            is_popular:
              type: boolean
            parent_ids:
              type: array
              items:
                type: string
            created_at:
              type: string
              format: date-time
            updated_at:
              type: string
              format: date-time

    CategoryTree:
      allOf:
        - $ref: '#/components/schemas/Category'
        - type: object
          properties:
            children:
              type: array
              items:
                $ref: '#/components/schemas/CategoryTree'

    User:
      type: object
      properties:
        id:
          type: integer
        username:
          type: string
        email:
          type: string
        role:
          type: string
          enum: [user, admin]

    Meta:
      type: object
      properties:
        total:
          type: integer
        page:
          type: integer
        per_page:
          type: integer

  securitySchemes:
    BearerAuth:
      type: http
      scheme: bearer
      bearerFormat: JWT
```

### 6. Генерация документации

```bash
# Генерация Swagger JSON из YAML
rake rswag:specs:swaggerize

# Просмотр документации
# Откройте http://localhost:3000/api-docs
```

### 7. Доступ к документации

После запуска приложения документация будет доступна по адресу:
- **Swagger UI**: `http://localhost:3000/api-docs`
- **Swagger JSON**: `http://localhost:3000/api-docs/v1/swagger.yaml`

---

**Примечание**: Это базовое руководство. Дополните его специфичными для вашего проекта деталями.

