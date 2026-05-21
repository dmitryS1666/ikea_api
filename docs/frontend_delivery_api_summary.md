# Frontend API: доставка и checkout

## 1. Кратко что изменилось

- Добавлены/используются delivery types: `europost_pickup`, `courier`, `ikeya_delivery`.
- Добавлена backward compatibility: `pickup` принимается как alias и нормализуется в `europost_pickup`.
- Добавлена проверка доступности типа доставки по ВГХ через `DeliveryOptionsService`.
- Добавлен `Delivery::ParcelPackingService` (parcel-level расчет: каждая единица товара как отдельная посылка).
- Добавлены множественные адреса пользователя:
  - `GET/POST/PATCH/DELETE /api/v1/account/delivery_addresses`.
- Добавлены сохраненные ПВЗ пользователя:
  - `GET/POST/DELETE /api/v1/account/pickup_points`.
- `POST /api/v1/delivery/calculate` теперь отдает дату доставки, хранение, цены и `display` блок.
- В ответе `delivery` добавлено поле **`pricing`**: `source` (откуда взята сумма сегмента «почта/Польша»), блок `internal` (таблицы `PolandDeliveryService` + `BelarusDeliveryService`) и при попытке расчёта Европочты — `europost` (успех/ошибка, `postal_total_byn`, `request_payload`). Для `europost_pickup` при заданном `EUROPOST_API_TOKEN` сегмент `delivery_price_byn` берётся из **`POST /api/external/postal/payment/calculate`**, при ошибке API или без токена — внутренний тариф Польши (fallback).
- `POST /api/v1/checkout` сохраняет расширенный delivery snapshot в `order.address_json` (старые ключи сохранены).
- `autolight` деактивирован/удален из активных API (routes/controller/swagger/providers).
- Legacy-read для старых заказов сохранен: сериализация заказа не падает, даже если в исторических данных встречаются старые значения.

## 2. Delivery types

| delivery_type | Название | Когда доступен | Что передавать |
|---|---|---|---|
| `europost_pickup` | ПВЗ Европочты | Когда корзина проходит **ВГХ-посылки** (`ParcelPackingService`); список подходящих ПВЗ — отдельно `GET .../europost_offices` с `cart_id`/`cart_token` | В `checkout`: `pickup_point_id` (`WarehouseId`) или `pickup_point` payload |
| `courier` | Курьер | Когда корзина проходит ВГХ-проверку | В `checkout`: `delivery_address_id` или `address` payload |
| `ikeya_delivery` | Доставка IKEYA | Когда корзина **не** проходит ВГХ-проверку (как fallback) | В `checkout`: `delivery_address_id` или `address` payload |
| `pickup` | Legacy alias | Поддерживается для backward compatibility | Нормализуется backend в `europost_pickup` |

Поведение недоступности:
- Если тип недоступен для текущей корзины -> `422` с `error`, `reason`, `available_methods`.

## 3. Логика ВГХ / “кубик”

### Что отвечает за расчет

- `Delivery::ParcelPackingService.call(cart)`:
  - строит `parcels` по `cart_items` с учетом `quantity`;
  - валидирует каждую parcel на соответствие лимитам Европочты;
  - возвращает итоговую пригодность корзины для Европочты.
- `DeliveryOptionsService.call(cart)`:
  - использует `ParcelPackingService`;
  - формирует `methods` (доступность `europost_pickup/courier/ikeya_delivery`);
  - отдает совместимый `cart_vgh` + новый `parcel_summary` + `parcels`.

### Какие поля товара используются

- `weight`
- `net_weight` (fallback)
- `package_volume`
- `package_dimensions`
- `dimensions`
- `full_attributes`

`package_volume` хранится и приходит от фронта в литрах (л/`l`), а проверки ВГХ Европочты выполняются в кубических метрах (`*_max_volume_m3`, `cart_vgh.volume_m3` в м³).

### Как учитывается quantity

- Каждая единица товара (`quantity = N`) разворачивается в `N` отдельных parcel-записей.
- Если хотя бы одна parcel не проходит, вся корзина не проходит Европочту.

### Причины недоступности (примеры)

- `missing_weight`
- `missing_dimensions`
- `missing_volume`
- `max_weight_exceeded`
- `max_volume_exceeded`
- `max_dimension_exceeded`
- `side_limits_exceeded` (если включены side limits в настройках)

### Бизнес-правило (по фактической реализации)

Если заказ проходит ВГХ:
- доступны `europost_pickup` и `courier`;
- `ikeya_delivery` помечается недоступной.

Если заказ не проходит ВГХ:
- доступна только `ikeya_delivery`;
- `europost_pickup` и `courier` недоступны.

### Что реально возвращается наружу API

- В `POST /api/v1/delivery/calculate` напрямую возвращаются:
  - `basis`
  - `delivery` (цены, даты, availability, display и т.д.)
  - `pickup_point`
- `parcel_summary` и `parcels` как отдельные поля в публичном ответе `delivery/calculate` сейчас **не возвращаются** (используются во внутренней логике доступности).

## 4. API flow для frontend

1. Открыть checkout экран, получить актуальную корзину.
2. Вызвать `POST /api/v1/delivery/calculate` с `cart_token` и выбранным `delivery_type`.
3. Прочитать доступность/цены/дату из `delivery`.
4. Если выбран `europost_pickup`:
   - получить ПВЗ через `GET /api/v1/delivery/europost_offices`;
   - при необходимости передать `cart_id`, чтобы получить только подходящие ПВЗ с ETA/ценами.
5. Если выбран `courier` или `ikeya_delivery`:
   - работать с адресами пользователя:
     - `GET /api/v1/account/delivery_addresses`
     - `POST/PATCH/DELETE /api/v1/account/delivery_addresses`.
6. (Опционально) сохранять/переиспользовать выбранные ПВЗ пользователя:
   - `GET/POST/DELETE /api/v1/account/pickup_points`.
7. Перед checkout отправить `POST /api/v1/checkout` с выбранным delivery type и обязательными данными по типу.
8. Backend создает заказ и сохраняет delivery snapshot в `order.address_json`.

## 5. Endpoint: расчет доставки

### `POST /api/v1/delivery/calculate`

- Auth: не обязателен (guest flow поддержан).
- Request:
  - `cart_token` (или `items` массив)
  - `delivery_type` (`pickup|europost_pickup|courier|ikeya_delivery`)
  - `pickup_point_id` (опционально)
- Response `200`:
  - `basis.total_weight_kg`
  - `basis.subtotal_byn`
  - `delivery.*`:
    - `type`
    - `delivery_type` (raw вход)
    - `normalized_delivery_type`
    - `available`
    - `delivery_date`
    - `storage_until`
    - `delivery_price_byn`
    - `delivery_to_belarus_price_byn`
    - `total_delivery_price_byn`
    - `display`
    - + legacy-поля стоимости/флагов (`base_cost_byn`, `poland_delivery_byn`, `belarus_delivery_byn`, `free_delivery_*`)
  - `pickup_point` (если передан `pickup_point_id`)
- Response `422`:
  - unsupported type (`Неподдерживаемый тип доставки`)
  - выбранный тип недоступен для корзины (`reason`, `available_methods`)

### Примеры request body

#### europost_pickup

```json
{
  "cart_token": "guest_token_123",
  "delivery_type": "europost_pickup",
  "pickup_point_id": 10
}
```

#### courier

```json
{
  "cart_token": "guest_token_123",
  "delivery_type": "courier"
}
```

#### ikeya_delivery

```json
{
  "cart_token": "guest_token_123",
  "delivery_type": "ikeya_delivery"
}
```

## 6. Endpoint: список ПВЗ Европочты

### `GET /api/v1/delivery/europost_offices`

- Auth: не обязателен.
- Query:
  - `cart_id` (опционально)
  - `type` (опционально, 1 / 3 / 4) — тип точки для REST `stores`

Поведение:
- без `cart_id`: список из `EuropostApiService.offices_out` (legacy JSON API), дополненный режимом работы из REST `GET /api/external/stores` при заданном `EUROPOST_API_TOKEN` (база `EUROPOST_API_BASE_URL`, по умолчанию `https://api-kassa.evropochta.by`).
- с `cart_id`: те же источники, ответ фильтруется по ВГХ корзины/лимитам отделения.
- query `type` (1, 3, 4) проксируется в Европочту как фильтр типа ПВЗ при запросе `stores`.

В cart-aware ответе каждый ПВЗ содержит:
- `working_hours` — одна строка на **текущий календарный день** приложения (`Time.zone` / `Date.today`): берётся слот из `schedules` с `iso_day_of_week` как у Ruby `Date#cwday` (пн=1 … вс=7); если на сегодня слота нет — строка `working_hours` + `break_hours` из ответа API; дальше legacy Info.
- `schedules` — **всегда 7 элементов** за текущую календарную неделю (пн–вс); дни без слота в ответе Европочты дополняются из `working_hours` / `break_hours`. В каждом элементе **`weekday_short`**: пн … вск (по `iso_day_of_week`).
- `break_hours`, `break` / `breaks` — как пришло из REST `stores`.
- `id` / `external_id` — `WarehouseId` Европочты, его можно передавать как `pickup_point_id` в checkout.
- `available_for_cart`
- `delivery_date`
- `storage_until`
- `delivery_price_byn`
- `delivery_to_belarus_price_byn`
- `total_delivery_price_byn`

Если корзина не проходит ВГХ — возвращается `offices: []`.

## 7. Endpoint: checkout

### `POST /api/v1/checkout`

- Auth: обязателен (`Bearer`).
- Ключевые поля:
  - `full_name`, `phone`, `delivery_type`, `payment_method`
  - `pickup_point_id` / `pickup_point` (для `europost_pickup`)
  - `delivery_address_id` / `address` (для `courier`, `ikeya_delivery`)

Проверки:
- `delivery_type` нормализуется (`pickup` -> `europost_pickup`).
- Доступность типа проверяется через `DeliveryOptionsService`.
- Цена доставки пересчитывается на backend.
- ETA считается через `DeliveryEtaService`.

Сохранение в заказ:
- `order.delivery_type` = normalized type.
- `order.delivery_price` = пересчитанный total delivery price.
- `order.address_json` сохраняет старые ключи + расширенный `delivery` snapshot.

## 8. Account API: адреса доставки

- `GET /api/v1/account/delivery_addresses`
- `POST /api/v1/account/delivery_addresses`
- `PATCH /api/v1/account/delivery_addresses/:id`
- `DELETE /api/v1/account/delivery_addresses/:id`

Особенности:
- пользователь видит/меняет только свои записи;
- удаление soft (`deleted_at`);
- есть `formatted_address` в serializer;
- правило private house применяется на backend (очистка `apartment/entrance/floor/has_elevator/intercom`).

## 9. Account API: сохраненные ПВЗ пользователя

- `GET /api/v1/account/pickup_points`
- `POST /api/v1/account/pickup_points`
- `DELETE /api/v1/account/pickup_points/:id`

Особенности:
- только свои записи;
- `provider` в новых пользовательских ПВЗ — только `europost`;
- повторный `POST` по `provider + external_id` не создает дубль (обновляет существующую запись);
- удаление soft (`deleted_at`).

## 10. Backward compatibility / legacy

- `delivery_type=pickup` поддержан как alias.
- Старые поля в `address_json` сохранены (добавлены новые, не удалены старые).
- `autolight` удален из активных API/документации/провайдеров.
- Legacy-read для старых заказов сохранен: `OrderSerializer` продолжает отдавать `address_json` как есть.

## 11. Что из ТЗ не используется/не реализовано как отдельный публичный контракт

- Отдельный endpoint “получить только parcel_summary” — не реализован.
- Публичная выдача `parcel_summary` в `delivery/calculate` — сейчас не возвращается напрямую (используется внутри `DeliveryOptionsService`).
