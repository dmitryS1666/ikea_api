# Доставка: корзина vs оформление (для фронта)

> **Полный пошаговый сценарий** (корзина → черновик → доставка → оплата, примеры запрос/ответ, правки фронта и бэка): [CART_CHECKOUT_FULL_FLOW.md](./CART_CHECKOUT_FULL_FLOW.md).

## Модель

| Этап | Эндпоинт | Назначение |
|------|----------|------------|
| **Корзина** | `GET /api/v1/cart` | Цены, логистика (внутренние тарифы), доступность способов доставки по ВГХ |
| **Оформление** | `POST /api/v1/delivery/calculate`, `GET /api/v1/delivery/europost_offices`, checkout | Выбор типа, API Европочты, ПВЗ, финальная цена доставки |

На корзине **не нужно** вызывать `POST /delivery/calculate` для отображения стоимости доставки до Беларуси.

---

## Изменения в `GET /api/v1/cart`

### Новый блок `cart.delivery`

```json
"delivery": {
  "pricing_source": "internal_cart",
  "total_weight_kg": 131.7,
  "delivery_poland_byn": "45.20",
  "delivery_to_belarus_byn": "87.63",
  "delivery_total_byn": "132.83",
  "available_methods": [
    { "code": "europost_pickup", "available": false, "reason": "max_weight_exceeded" },
    { "code": "courier", "available": false, "reason": "max_weight_exceeded" },
    { "code": "ikeya_delivery", "available": true, "reason": null }
  ],
  "europost_eligible": false,
  "ineligible_reason": "max_weight_exceeded"
}
```

- **`delivery_to_belarus_byn`** — логистика по РБ (wc_by), для строки «доставка в Беларусь» на корзине.
- **`delivery_poland_byn`** — доставка в PLN-тарифах товаров (сумма `delivery_cost` по позициям).
- **`delivery_total_byn`** — PL + РБ (дублирует `totals.delivery_total_byn`).
- **`available_methods`** — какие способы возможны на checkout (без вызова Europost API).

### Дополнение `cart.totals`

Те же поля в totals (строки `"xx.xx"`):

- `delivery_poland_byn`
- `delivery_to_belarus_byn`

Существующие поля без изменений: `items_total_byn`, `delivery_total_byn`, `total_byn`, `total_weight_kg`, пошлина, промо.

### Частичный выбор (чекбоксы): `POST /api/v1/cart/summary`

`GET /cart` всегда считает **всю** корзину. Для итогов только по отмеченным товарам:

```http
POST /api/v1/cart/summary
Content-Type: application/json

{
  "cart_token": "...",
  "items": [
    { "sku": "90205097", "quantity": 1 }
  ]
}
```

Ответ (строки BYN в формате `"xx.xx"`):

- **`items[]`** — цены по **выбранным** SKU/qty (с наценкой, как в `GET /cart` → `items[].pricing`):
  - `sku`, `quantity`
  - `pricing.unit_price_new_byn`, `pricing.line_total_new_byn`, промо-поля
- `items_count`, `subtotal_new_byn`, `discount_total_byn`, `customs_total_byn`
- `delivery_to_belarus_byn`, `delivery_total_byn`, `total_weight_kg`, `total_byn`
- `delivery.available_methods`, `delivery.europost_eligible`
- `meta.checkout_allowed`, `meta.min_order_error` — минимальная сумма заказа по **выбранным** позициям

**UI:** цену строки берите из `items[].pricing`. `subtotal_new_byn` — витринная «Стоимость товаров» (без доставки в РБ), та же сумма для `meta.checkout_allowed` и минимального заказа.

Тот же массив `items` передаётся в `POST /checkout` (`draft: true`) и в `POST /checkout/:id/finalize`.

---

## Что убрать / не делать на корзине

| Было (проблемно) | Стало |
|------------------|--------|
| `POST /delivery/calculate` + `pickup` на корзине → **422** без цен | Использовать **`GET /cart`** → всегда **200** |
| Ожидание `delivery_to_belarus_price_byn` из calculate на корзине | Брать **`cart.delivery.delivery_to_belarus_byn`** или **`cart.totals.delivery_to_belarus_byn`** |

---

## Оформление (без изменений контракта)

1. Показать способы из `cart.delivery.available_methods` (или повторить логику после обновления корзины).
2. Для **Европочты**: `GET /delivery/europost_offices?order_id=...` (на checkout) или `?cart_token=...` (+ `items` для subset на корзине) — список ПВЗ с ценами (если `europost_eligible`). Без контекста — полный публичный каталог (страница `/pvz`, ЛК), без цен доставки.
3. Для выбранного типа: `POST /delivery/calculate` с `delivery_type` и при ПВЗ — `pickup_point_id`.
   - Крупногабарит: **`ikeya_delivery`**, не `pickup` / `europost_pickup`.
   - При недоступном типе — **422** (это нормально на checkout).
4. Checkout / finalize с тем же `delivery_type`.

### Поля `POST /delivery/calculate` (checkout)

Без изменений: `delivery_to_belarus_price_byn`, `total_delivery_price_byn`, `pricing.europost`, ETA и т.д.

---

## Сводка для UI

| Данные | Корзина | Checkout |
|--------|---------|----------|
| Цена строки | `items[].pricing.line_total_new_byn` | то же + пересчёт заказа |
| Доставка до РБ | `cart.delivery.delivery_to_belarus_byn` | `delivery.delivery_to_belarus_price_byn` из calculate |
| Итого логистика | `cart.totals.delivery_total_byn` | `delivery.total_delivery_price_byn` |
| Европочта доступна? | `cart.delivery.europost_eligible` | `available_methods` / offices |
| API Europost | **нет** | **да** (offices + calculate) |
