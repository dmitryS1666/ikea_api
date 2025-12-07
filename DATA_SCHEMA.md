# 📊 Схемы данных

## 🗄️ База данных: MongoDB

**Имя базы данных**: `ikea`

---

## 📦 Коллекция: `products`

### Схема модели Product

```javascript
{
  // Идентификаторы
  sku: String,                    // Уникальный ID товара (обязательное, уникальное)
  uniqueId: Number,               // Уникальный цифровой ID для Deal.by (уникальное, sparse)
  itemNo: String,                 // Артикул товара (itemNoGlobal || itemNo)
  url: String,                    // URL страницы товара на IKEA Poland
  
  // Названия
  name: String,                    // Название товара (польское)
  nameRu: String,                 // Название товара (русское)
  collection: String,             // Название коллекции
  
  // Связанные товары
  variants: [String],             // Массив артикулов вариантов товара
  relatedProducts: [String],      // Массив артикулов связанных товаров
  setItems: [String],             // Массив артикулов предметов в наборе
  bundleItems: [String],         // Массив артикулов товаров в комплекте
  
  // Медиа
  images: [String],               // Массив URL изображений (внешние ссылки)
  localImages: [String],          // Массив локальных путей к изображениям
  imagesTotal: Number,            // Всего изображений (по ссылкам)
  imagesStored: Number,           // Сколько сохранено локально
  imagesIncomplete: Boolean,      // Флаг: не все изображения загружены
  videos: [String],              // Массив URL видео (YouTube, Vimeo, прямые ссылки)
  manuals: [String],             // Массив URL инструкций по сборке
  
  // Цена и наличие
  price: Number,                  // Цена товара в PLN
  quantity: Number,               // Количество товара на складе
  homeDelivery: String,           // Доступность доставки на дом
  
  // Характеристики
  weight: Number,                 // Вес товара в кг (общий вес всех упаковок)
  netWeight: Number,              // Вес нетто товара в кг
  packageVolume: Number,         // Объем упаковки в см³
  packageDimensions: String,      // Размеры упаковки (Д × Ш × В) в см
  dimensions: String,            // Размеры товара (текст)
  isParcel: Boolean,              // Является ли товар посылкой (для GLS)
  
  // Описания (русские переводы)
  content: String,               // Описание товара (HTML)
  contentRu: String,             // Русский перевод content
  materialInfo: String,          // Информация о материалах (HTML)
  materialInfoRu: String,        // Русский перевод materialInfo
  goodInfo: String,              // Дополнительная информация (HTML)
  goodInfoRu: String,            // Русский перевод goodInfo
  translated: Boolean,           // Флаг наличия перевода с IKEA Lithuania
  
  // Флаги
  isBestseller: Boolean,         // Хит продаж (с главной страницы)
  isPopular: Boolean,            // Популярный товар (с главной страницы)
  
  // Связи
  categoryId: String,            // ID категории товара (может быть пустым для популярных товаров)
  filterValues: [ObjectId],      // Массив ссылок на FilterValue
  
  // Доставка (автоматически рассчитывается)
  deliveryType: String,          // Тип доставки: 'with_carry', 'without_carry', 'gls_point'
  deliveryName: String,         // Название типа доставки
  deliveryCost: Number,         // Стоимость доставки в PLN
  deliveryReason: String,       // Причина выбора типа доставки
  
  // Timestamps
  createdAt: Date,              // Дата создания
  updatedAt: Date               // Дата обновления
}
```

### Индексы
- `sku` (уникальный)
- `uniqueId` (уникальный, sparse)
- `updatedAt` (для сортировки)

### Middleware
- **pre('save')**: Генерация `uniqueId`
- **pre('findOneAndUpdate')**: Генерация `uniqueId` при upsert
- **post('save')**: Автоматический расчет доставки
- **post('findOneAndUpdate')**: Пересчет доставки при изменении веса/цены

---

## 📂 Коллекция: `categories`

### Схема модели Category

```javascript
{
  // Идентификаторы
  id: String,                    // Уникальный ID категории из IKEA (обязательное, уникальное)
  uniqueId: Number,              // Уникальный цифровой ID для Deal.by (уникальное, sparse)
  
  // Названия
  name: String,                  // Название категории (польское, обязательное)
  translatedName: String,        // Название категории (русское, автоматический перевод)
  
  // Метаданные
  url: String,                   // URL категории на IKEA (обязательное)
  remoteImageUrl: String,        // URL изображения категории
  localImagePath: String,        // Локальный путь к изображению
  
  // Иерархия
  parentIds: [String],           // Массив ID родительских категорий
  
  // Флаги
  isDeleted: Boolean,            // Мягкое удаление
  isImportant: Boolean,          // Важная категория
  isPopular: Boolean,            // Популярная категория (с главной страницы)
  
  // Timestamps
  createdAt: Date,
  updatedAt: Date
}
```

### Индексы
- `id` (уникальный)
- `uniqueId` (уникальный, sparse)

### Middleware
- **pre('save')**: 
  - Генерация `uniqueId`
  - Автоматический перевод `name` → `translatedName` через Google Translate

---

## 🔍 Коллекция: `filters`

### Схема модели Filter

```javascript
{
  parameter: String,             // Уникальный параметр фильтра (обязательное, уникальное)
  name: String,                  // Название фильтра (польское)
  nameRu: String,               // Название фильтра (русское, автоматический перевод)
  
  // Timestamps
  createdAt: Date,
  updatedAt: Date
}
```

### Индексы
- `parameter` (уникальный)

### Middleware
- **pre('save')**: Автоматический перевод `name` → `nameRu` через Google Translate

---

## 🎨 Коллекция: `filtervalues`

### Схема модели FilterValue

```javascript
{
  filter: ObjectId,             // Ссылка на Filter (обязательное)
  valueId: String,               // Уникальный ID значения (обязательное, уникальное)
  name: String,                  // Название значения (польское, обязательное)
  nameRu: String,               // Название значения (русское, автоматический перевод)
  hex: String,                  // HEX код цвета (для цветовых фильтров)
  
  // Timestamps
  createdAt: Date,
  updatedAt: Date
}
```

### Индексы
- `valueId` (уникальный)
- `filter` (для связи с Filter)

### Middleware
- **pre('save')**: Автоматический перевод `name` → `nameRu` через Google Translate

---

## 👤 Коллекция: `users`

### Схема модели User

```javascript
{
  username: String,              // Имя пользователя (обязательное, уникальное)
  password: String,               // Хеш пароля (обязательное, bcrypt)
  email: String,                 // Email (уникальное, sparse)
  role: String,                  // Роль: 'user' или 'admin' (по умолчанию: 'user')
  isActive: Boolean,             // Активен ли пользователь (по умолчанию: true)
  
  // Timestamps
  createdAt: Date,
  updatedAt: Date
}
```

### Индексы
- `username` (уникальный)
- `email` (уникальный, sparse)

### Middleware
- **pre('save')**: Хеширование пароля через bcrypt

### Методы
- `comparePassword(plain)` - сравнение пароля с хешем

---

## 🚚 Коллекция: `deliveries` (опционально)

### Схема модели Delivery

```javascript
{
  weight: Number,                // Вес в кг (обязательное, min: 0)
  deliveryType: String,          // Тип доставки (обязательное)
                                  // 'with_carry', 'without_carry', 'gls_home', 'gls_point'
  isIkeaFamily: Boolean,         // Член IKEA Family (по умолчанию: true)
  orderValue: Number,            // Стоимость заказа в PLN (обязательное, min: 0)
  isWeekend: Boolean,            // Доставка в выходной день (по умолчанию: false)
  
  // Timestamps
  createdAt: Date,
  updatedAt: Date
}
```

### Статические методы
- `calculateDeliveryCost(deliveryData)` - расчет стоимости доставки
- `calculateWithCarryCost(weight, isIkeaFamily, isWeekend)` - расчет с заносом
- `calculateWithoutCarryCost(weight, isIkeaFamily, isWeekend)` - расчет без заноса
- `calculateGlsHomeCost(orderValue, isIkeaFamily)` - расчет GLS курьер
- `calculateGlsPointCost(orderValue, isIkeaFamily)` - расчет GLS пункт

---

## 🔗 Связи между моделями

### Product ↔ Category
```
Product.categoryId → Category.id (String, не ObjectId)

Примечание:
- В API ответах для товаров добавляется поле categoryName через MongoDB $lookup
- categoryName берется из Category.translatedName или Category.name
- categoryId может быть пустым для популярных товаров, добавленных с главной страницы
```

### Product ↔ FilterValue
```
Product.filterValues → FilterValue._id (ObjectId)
```

### FilterValue ↔ Filter
```
FilterValue.filter → Filter._id (ObjectId)
```

---

## 📊 Источники данных

### Из IKEA Poland (🇵🇱) - Основной источник (~85% параметров)

**API поиска (`sik.search.blue.cdtapps.com/pl/pl/search`):**
- `sku` - `prod.id`
- `name` - `prod.typeName`
- `itemNo` - `prod.itemNoGlobal || prod.itemNo`
- `url` - `prod.pipUrl`
- `variants` - `prod.gprDescription.variants`
- `price` - `prod.salesPrice.numeral`
- `categoryId` - из параметров запроса
- `homeDelivery` - `prod.homeDelivery`

**HTML страницы (`ikea.com/pl/pl/p/...`):**
- `images` - JSON-LD `productSchema.image`
- `collection` - `.pip-header-section__title--big`
- `weight` - `stockcheckSection.packagingProps.packages` (сумма весов всех упаковок)
- `netWeight` - `stockcheckSection.packagingProps.packages[].netWeight` или `measurements[][].value` где `type === 'netWeight'`
- `packageVolume` - `stockcheckSection.packagingProps.packages[].volume` или расчет из `width × height × length`
- `packageDimensions` - `stockcheckSection.packagingProps.packages[].measurements` (Д × Ш × В в см)
- `dimensions` - `productData` или JSON-LD
- `relatedProducts` - `productData.addOns.addOns`
- `manuals` - `productInformationSection.attachments.manual`
- `videos` - `productData.videoSection`, `mediaSection`, HTML `iframe`/`video`
- `setItems` - `productData.productSetSection.items` или HTML
- `bundleItems` - `productData.bundleSection.items` или HTML

**API наличия (`api.salesitem.ingka.com`):**
- `quantity` - `buyingOption.homeDelivery.availability.quantity`
- `isParcel` - `buyingOption.homeDelivery.availability.parcel`

### Из IKEA Lithuania (🇱🇹) - Только русские переводы (~15% параметров)

**HTML страницы (`ikea.lt/ru/search/?q={itemNo}`):**
- `nameRu` - `h1 .itemFacts` (с очисткой от доп. информации)
- `materialInfo` - `#materials-details`
- `content` - `.product-details-content`
- `goodInfo` - `#good-details`
- `translated` - `true` если товар найден на ikea.lt

### Автоматически рассчитывается

**Доставка (middleware `deliveryService.js`):**
- `deliveryType` - расчет на основе веса и `isParcel`
- `deliveryName` - название типа доставки
- `deliveryCost` - стоимость доставки в PLN
- `deliveryReason` - причина выбора типа доставки

**Уникальные ID (middleware):**
- `uniqueId` - для Product и Category (атомарная генерация)

**Переводы (middleware `translateService.js`):**
- `translatedName` - для Category (Google Translate API)
- `nameRu` - для Filter и FilterValue (Google Translate API)
- `nameRu` - для Product (DeepL API или Google Translate API, если нет перевода с IKEA Lithuania)
- `contentRu`, `materialInfoRu`, `goodInfoRu` - для Product (Google Translate API, опционально)

---

## 🔄 Автоматические операции

### При сохранении Product
1. Генерация `uniqueId` (если не указан)
2. Расчет доставки (если указан вес)
3. Обновление полей `deliveryType`, `deliveryName`, `deliveryCost`, `deliveryReason`

### При сохранении Category
1. Генерация `uniqueId` (если не указан)
2. Автоматический перевод `name` → `translatedName`

### При сохранении Filter/FilterValue
1. Автоматический перевод `name` → `nameRu`

---

## 📝 Примеры документов

### Product
```json
{
  "_id": "69268e9d69c767c437aa079b",
  "sku": "403.411.01",
  "uniqueId": 15660,
  "name": "IKEA 365+ Serwis, 18 szt. - biały",
  "nameRu": "сервиз",
  "itemNo": "40341101",
  "url": "https://www.ikea.com/pl/pl/p/ikea-365-serwis-18-szt-bialy-40341101/",
  "price": 0,
  "weight": 9.17,
  "netWeight": 0,
  "packageVolume": 0,
  "packageDimensions": "",
  "dimensions": "Ш: 29см, В: 27см, Г: 30см",
  "images": ["https://www.ikea.com/pl/pl/images/products/..."],
  "localImages": [],
  "isBestseller": true,
  "isPopular": true,
  "categoryId": "10412",
  "deliveryType": "without_carry",
  "deliveryName": "Доставка без заноса",
  "deliveryCost": 69,
  "deliveryReason": "Вес до 200 кг - доставка без заноса",
  "createdAt": "2025-11-26T05:22:37.554Z",
  "updatedAt": "2025-11-26T11:07:28.094Z"
}
```

### Category
```json
{
  "_id": "69243f6b8daace31c8fd34bf",
  "id": "10412",
  "uniqueId": 5,
  "name": "Kredensy i bufety",
  "translatedName": "Серванты и буфеты",
  "url": "/pl/pl/cat/kredensy-i-bufety-10412/",
  "parentIds": ["st003", "30454"],
  "isDeleted": false,
  "isImportant": false,
  "isPopular": true,
  "createdAt": "2025-11-24T11:20:11.199Z",
  "updatedAt": "2025-11-26T11:07:36.716Z"
}
```

---

## 🔄 API ответы

### Дополнительные поля в API ответах (не хранятся в БД)

При запросе товаров через API (`/api/products/admin`, `/api/products/admin/:id`) добавляются следующие поля через MongoDB aggregation `$lookup`:

- `categoryName` - Название категории (из `Category.translatedName` или `Category.name`)
  - Получается через lookup: `Product.categoryId` → `Category.id`
  - Если категория не найдена, возвращается пустая строка

### Пример API ответа

```json
{
  "sku": "403.411.01",
  "name": "IKEA 365+ Serwis, 18 szt. - biały",
  "categoryId": "10412",
  "categoryName": "Kredensy i bufety",
  ...
}
```

---

## 📚 Дополнительная информация

Подробнее о архитектуре приложения см. [ARCHITECTURE.md](./ARCHITECTURE.md)

