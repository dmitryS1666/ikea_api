# frozen_string_literal: true

require 'rails_helper'

RSpec.configure do |config|
  # Specify a root folder where Swagger JSON files are generated
  # NOTE: If you're using the rswag-api to serve API descriptions, you'll need
  # to ensure that it's configured to serve Swagger from the same folder
  config.openapi_root = Rails.root.join('swagger').to_s

  # Define one or more Swagger documents and provide global metadata for each one
  # When you run the 'rswag:specs:swaggerize' rake task, the complete Swagger will
  # be generated at the provided relative path under openapi_root
  # By default, the operations defined in spec files are added to the first
  # document below. You can override this behavior by adding a openapi_spec tag to the
  # the root example_group in your specs, e.g. describe '...', openapi_spec: 'v2/swagger.json'
  config.openapi_specs = {
    'v1/swagger.yaml' => {
      openapi: '3.0.1',
      info: {
        title: 'IKEA API',
        version: 'v1',
        description: <<~DESC
          API для работы с данными IKEA парсера.

          ## Аутентификация
          Большинство эндпоинтов для получения данных (товары, категории, главная страница) являются **публичными** и не требуют токена.

          JWT токен в заголовке `Authorization: Bearer <token>` требуется только для действий, связанных с пользователем (отзывы, личный кабинет).

          **Публичные эндпоинты (Без токена):**
          - `GET /api/v1/products` — Список товаров
          - `GET /api/v1/products/{sku}` — Карточка товара
          - `GET /api/v1/products/bestsellers` — Бестселлеры
          - `GET /api/v1/products/popular` — Популярные товары
          - `GET /api/v1/categories` — Категории
          - `GET /api/v1/categories/{id}/products` — Товары в категории
          - `GET /api/v1/homepage/slider/main` — Слайдер на главной
          - `POST /api/v1/auth/login` — Вход
          - `POST /api/v1/auth/register` — Регистрация

          **Приватные эндпоинты (Требуется Bearer Token):**
          - `POST /api/v1/products/{sku}/reviews` — Оставить отзыв
          - `GET /api/v1/account/reviews` — Мои отзывы
          - `PATCH/DELETE /api/v1/reviews/{id}` — Управление своими отзывами

          Получить токен можно через `/api/v1/auth/login`
        DESC
      },
      paths: {},
      servers: [
        { url: 'http://45.135.234.22', description: 'Production server (IP)' },
        { url: 'http://localhost:3000', description: 'Development server' }
      ]
    }
  }

  # Specify the format of the output Swagger file when running 'rswag:specs:swaggerize'.
  # The openapi_specs configuration option has the filename including format in
  # the key, this may want to be changed to avoid putting yaml in json files.
  # Defaults to json. Accepts ':json' and ':yaml'.
  config.openapi_format = :yaml
end
