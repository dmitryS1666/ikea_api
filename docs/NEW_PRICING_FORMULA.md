# Новая формула цены IKEYA

Канонический документ. Все витринные, корзинные, checkout, XLSX, search и admin-расчёты обязаны использовать `PriceCalculationService` / `CartPricingService`. Формулу нельзя дублировать в serializers, контроллерах или экспортах.

## Обозначения

- `IKEA` — `Product#price`, актуальная брутто-цена IKEA Poland, PLN.
- `priceAddonPln` — `Product#price_addon_pln`, ручная надбавка PLN на одну единицу, `>= 0`.
- `P = IKEA + max(0, priceAddonPln)`.
- `W` — полный транспортировочный вес одной единицы: сумма всех коробок через `Products::WeightExtractor.packaging_weight_kg_for_product`.
- `D_IKEA` — `Product#delivery_cost`, доставка IKEA.pl одной единицы до склада `ul. Octowa 24, 15-399 Białystok`.
- `WC` — весовая логистика одной единицы (`BelarusDeliveryService`).
- Mix-лоты в этой версии не используются.

## Goods

Если `P <= pricing_cheap_threshold_pln` (по умолчанию 150):

```
goods = P × pricing_cheap_multiplier   # 1.30
```

Если `P > 150`:

```
K = max(pricing_min_markup, pricing_target_profit_pln / P − pricing_markup_subtrahend)
goods = P × (1 + K)
```

Множитель 1.3 и K применяются **только к P**. `D_IKEA` и `WC` не умножаются.

Режим cheap/k выбирается по `P`, не по сырому `IKEA`.

## WC — не прогрессивная шкала

Для всего веса единицы берётся ставка диапазона:

| Вес единицы | Ставка PLN/кг (по умолчанию) |
|---|---|
| W ≤ 20 | 16.85 |
| 20 < W ≤ 30 | 12.81 |
| 30 < W ≤ 40 | 10.69 |
| W > 40 | 8.58 |

Примеры: `20 кг → 20 × 16.85`; `20.01 кг → 20.01 × 12.81`. Скачки на 20/30/40 ожидаемы.

`quantity` **не** объединяет вес:

```
WC_line = WC_unit × quantity
```

Нельзя считать `BelarusDeliveryService.calculate(W_unit × quantity)`.

То же для `D_IKEA_line = D_IKEA_unit × quantity`.

## База без таможни

```
basePriceByn = round2((goods + D_IKEA + WC) × PLN_BYN_raw × exchange_rate_buffer)
```

`exchange_rate_buffer` по умолчанию 1.05. На таможню не применяется.

## Таможня одной единицы (карточка)

Таможенная база **не** от P, goods, addon, D_IKEA, WC и маржи:

```
C = (IKEA / poland_vat_multiplier) × (PLN_BYN_raw / EUR_BYN_raw)
```

VAT по умолчанию 1.23. `C` не округляется до сравнения с лимитом 200 EUR.

`CustomsDutyService.calculate(C, W, EUR_BYN_raw)`:

- C = 200 или W = 31 → duty = 0
- только C > 200 → `(C − 200) × 0.15 × EUR`
- только W > 31 → `(W − 31) × 2 × EUR`
- оба превышены → `max(cost, weight) × EUR`
- если duty > 0: `customs = round2(duty) + customs_fee` (10 BYN один раз)

## Карточка

Обычный товар (`C ≤ 200` и `W ≤ 31`):

```
cardPrice = basePriceByn
customs_included_in_card_price = false
```

Если одна единица уже сама превышает лимит:

```
cardPrice = basePriceByn + individualCustoms
customs_included_in_card_price = true
```

Публичный API:

- `price_byn` — отображаемая цена карточки
- `base_price_byn`
- `display_price_byn` (= card)
- `customs_estimate_byn`
- `customs_included_in_card_price`
- `customs_threshold_exceeded`
- `pricing_available`
- `pricing_status` (`ok` / `requires_clarification`)
- `pricing_errors` (`missing_weight`, `missing_ikea_delivery`, …)
- `customs_notice`

Текст витрины:

«Таможенный сбор рассчитывается в корзине, если заказ дороже 200 € или тяжелее 31 кг»

Если `pricing_available = false`, UI показывает «Цена уточняется», товар нельзя оформить.

## Корзина

Карточный customs **не суммируется**. Корзина всегда пересчитывает:

```
cartCustomsCostEur = SUM((IKEA_unit / VAT) × qty) × PLN_EUR
cartWeightKg = SUM(W_unit × qty)
cartCustoms = CustomsDutyService.calculate(cartCustomsCostEur, cartWeightKg, EUR_BYN_raw)
```

Сбор 10 BYN — один раз на корзину.

```
items_total_byn = SUM(basePriceByn единиц)   # turnkey: goods + D_IKEA + WC
cartFinal = items_total_byn − promo + cartCustoms + local_delivery_total_byn
```

Promo применяется только к `basePriceByn`, никогда к customs и никогда к C.

`delivery_to_belarus_byn` и `delivery_poland_byn` — breakdown уже включённых в items сумм. Их нельзя прибавлять второй раз.

`delivery_total_byn` / `local_delivery_total_byn` — last-mile покупателю (Европочта / курьер / IKEYA), не D_IKEA и не WC.

## D_IKEA

Хранится в `product.delivery_cost`. Авторасчёт: `IkeaDeliveryService` по JSON-настройке `ikea_delivery_config`.

Код **не подставляет** тарифы IKEA.pl. Администратор должен включить методы (`enabled: true`) и заполнить реальные `cost_pln`, ограничения веса/габаритов.

Существующие `delivery_cost` не сбрасываются. Если админ правил стоимость вручную, ставится `delivery_cost_manual`.

После изменения `ikea_delivery_config` ставится `Products::RecalculateIkeaDeliveryJob` для товаров без ручного override.

## Отсутствующие данные

`nil` веса или `nil` D_IKEA ≠ 0.

- `pricing_available: false`
- checkout server-side блокируется (`CartPricingService` / `CheckoutService`)

## Настройки CalculatorSetting

| Ключ | Default | Смысл |
|---|---|---|
| `pricing_cheap_threshold_pln` | 150 | порог P |
| `pricing_cheap_multiplier` | 1.30 | только на P |
| `pricing_target_profit_pln` | 87 | K |
| `pricing_markup_subtrahend` | 0.187 | K |
| `pricing_min_markup` | 0.10 | пол K |
| `exchange_rate_buffer` | 1.05 | не на таможню |
| `poland_vat_multiplier` | 1.23 | база C |
| `belarus_delivery_rates` | JSON WC | ставка за весь вес диапазона |
| `ikea_delivery_config` | JSON D_IKEA | методы/лимиты/cost_pln |
| `poland_delivery_rates` | legacy | калькулятор, пока не заменён конфигом |
| `customs_*` | 200 / 31 / 0.15 / 2 / 10 | как раньше |

`initialize_defaults` создаёт только отсутствующие ключи и **не** затирает значения админа.

Изменение любого price-affecting ключа сбрасывает `Categories::ShowCache`.

## Примеры

### Обычный товар

IKEA = 100, addon = 0, W = 10, D_IKEA = 20, PLN_BYN = 1, buffer = 1.05

- P = 100, goods = 130
- WC = 10 × 16.85 = 168.5
- subtotal PLN = 318.5
- base/card BYN = round2(318.5 × 1.05) = 334.43
- C мал, W ≤ 31 → customs на карточке 0

### Товар сам превышает таможню

IKEA = 985, W = 10, PLN_BYN = 1, EUR_BYN = 4

- C > 200
- card = base + individualCustoms

### Два «безопасных» товара в корзине

Каждый C = 150 EUR, W = 10.

Карточки: customs = 0.

Корзина: C_total = 300 → duty = 100 × 0.15 = 15 EUR = 60 BYN при EUR=4, плюс сбор 10 → **70 BYN** один раз.

## API для frontend (репозиторий `ikeya`)

Карточка читает `price_byn` / `pricing_available` / `customs_notice` / `customs_included_in_card_price`.

Корзина:

```
final = items_total_byn − discount_total_byn + customs_total_byn + delivery_total_byn
```

где `delivery_total_byn` — только last-mile. WC уже внутри `items_total_byn`.

Оформление запрещено, если `meta.checkout_allowed = false` или `pricing_available = false` у позиции.

## Что заполнить в админке для авто-D_IKEA

Ключ: `ikea_delivery_config` (Системные настройки, группа «Доставка»).

Вшитый default — регулярные тарифы IKEA.pl **с 08.09.2026**, зона **A**, адрес склада `ul. Octowa 24, 15-399 Białystok`.

`use_member_prices: false` — **не** 7/14/79 Family. Если закупки идут через IKEA Family / Business Network, это нужно сменить вручную.

### GLS не по одному весу

IKEA пишет, что курьер GLS доступен не для любого товара даже при подходящем весе. Проверка в корзине IKEA у нас недоступна.

Правило в коде:

```
если requires_product_eligibility = true
  нужны габариты ВСЕХ коробок
  и коробки проходят лимиты GLS Polska: 200 × 80 × 60 см, girth ≤ 300 см
  0 < W ≤ 25  → 19.99
  25 < W ≤ 50 → 29.99
иначе
  транспортная сетка по весу единицы
```

Товар 4 кг без размеров коробок получит **99 PLN** (transport), не 19.99.

### Транспорт зона A

| Вес единицы | PLN | Услуга |
|---|---|---|
| ≤ 50 | 99 | bez wniesienia |
| 50–100 | 139 | bez wniesienia |
| 100–200 | 189 | bez wniesienia |
| 200–400 | 349 | z wniesieniem |
| 400–600 | 519 | z wniesieniem |
| 600–1000 | 619 | z wniesieniem |

Bez wniesienia ограничен 200 кг — дальше только z wniesieniem.

После сохранения конфига ставится `Products::RecalculateIkeaDeliveryJob` для товаров без `delivery_cost_manual`.
