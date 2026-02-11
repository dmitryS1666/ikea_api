# Swagger (rswag) — как добавлять описание новых эндпоинтов

В проекте Swagger/OpenAPI **генерируется** из rswag request-spec’ов командой:

```bash
bundle exec rake rswag:specs:swaggerize
```

Файл `swagger/v1/swagger.yaml` **не редактируется вручную** — он перезаписывается генератором.

## Где задаётся глобальная информация (title/version/description/servers)

Файл: `spec/swagger_helper.rb`

- `info` — заголовок, версия, описание
- `servers` — список серверов для Swagger UI
- `components/securitySchemes` (если добавлено) — описывает Bearer/JWT

## Где добавлять описание эндпоинтов

Создавай rswag-спеки в `spec/requests/...` (обычно по фиче или по контроллеру), например:

- `spec/requests/api/v1/products_spec.rb`
- `spec/requests/api/v1/delivery_spec.rb`

**Важно:** rswag добавляет в Swagger только то, что описано в спеках. Если у эндпоинта нет rswag-спеки — он не появится в `paths:`.

## Мини-шаблон для нового эндпоинта

```ruby
require 'swagger_helper'

RSpec.describe 'Some Feature', type: :request do
  path '/api/v1/some_endpoint' do
    get 'human readable summary' do
      tags 'SomeTag'
      produces 'application/json'

      parameter name: :q, in: :query, type: :string, required: false

      response '200', 'successful' do
        run_test!
      end
    end
  end
end
```

## Публичный vs приватный эндпоинт (JWT)

Если эндпоинт должен быть **приватным** (нужен токен), добавь:

```ruby
security [bearer_auth: []]
```

И обязательно опиши ответ `401`:

```ruby
response '401', 'unauthorized' do
  run_test!
end
```

Если не хочешь заводить токен в спеках — можно документировать только `401` (и/или `422`) для приватных ручек, чтобы генерация Swagger не падала.

## Как не «сломать» генерацию

- Не делай `response '200'` для эндпоинта, который в тестовом окружении вернёт `401/403/422` без доп. подготовки.
- Для `show` (например `/products/{sku}`) либо:
  - создавай данные в БД в спеке, если модель позволяет (`let!(:record) { ... }`), либо
  - документируй `404` как базовый кейс (так генерация не потребует fixture).

## Быстрая проверка

1) Запусти генерацию:
```bash
bundle exec rake rswag:specs:swaggerize
```

2) Проверь, что `swagger/v1/swagger.yaml` обновился и содержит новые `paths`.

3) Открой Swagger UI (если подключён rswag-api), либо используй сам yaml.
