# 🔍 SEO-оптимизация для React SPA + Rails API (2025)

## 📋 Архитектура проекта

- **Backend**: Rails API (`config.api_only = true`)
- **Frontend**: React SPA (отдельное приложение)
- **Проблема**: React SPA не индексируется поисковыми системами без SSR

---

## 🎯 Актуальные SEO-требования 2025 года

### 1. **Core Web Vitals (Google)**
- ⚡ **LCP (Largest Contentful Paint)** < 2.5s
- ⚡ **FID (First Input Delay)** < 100ms
- ⚡ **CLS (Cumulative Layout Shift)** < 0.1

### 2. **Server-Side Rendering (SSR)**
- ✅ HTML с контентом при первой загрузке
- ✅ Meta-теги в `<head>` при рендере
- ✅ Структурированные данные (JSON-LD) в HTML

### 3. **Meta-теги (обязательные)**
- `<title>` - уникальный для каждой страницы
- `<meta name="description">` - описание (150-160 символов)
- Open Graph (`og:title`, `og:description`, `og:image`, `og:url`)
- Twitter Cards
- Canonical URL
- `<meta name="viewport">` для мобильных

### 4. **Структурированные данные (Schema.org)**
- **Product** schema для товаров
- **BreadcrumbList** для навигации
- **Organization** для компании
- **WebSite** с поиском
- **FAQPage** (если есть FAQ)

### 5. **Технические файлы**
- `sitemap.xml` - карта сайта (динамическая генерация)
- `robots.txt` - правила для роботов
- `favicon.ico` и Apple Touch Icons

### 6. **Производительность**
- Code splitting
- Lazy loading изображений
- Оптимизация изображений (WebP, AVIF)
- Минификация и сжатие (gzip/brotli)

### 7. **Мобильная оптимизация**
- Responsive design
- Mobile-first подход
- Touch-friendly интерфейс

---

## 🚀 Вариант 1: Next.js (SSR/SSG) ⭐ Рекомендуется

### Описание
Миграция React SPA на Next.js с поддержкой Server-Side Rendering (SSR) и Static Site Generation (SSG).

### Архитектура
```
Next.js App (SSR/SSG)
├── Pages с SSR → HTML при запросе
├── Pages с SSG → Статические HTML
└── API Routes → Прокси к Rails API (опционально)
     ↓
Rails API (остается как есть)
```

### Преимущества
- ✅ **Нативная поддержка SSR** - встроенная в Next.js
- ✅ **Отличный SEO** - полный HTML при первой загрузке
- ✅ **Производительность** - автоматическая оптимизация
- ✅ **Image Optimization** - встроенная оптимизация изображений
- ✅ **Code Splitting** - автоматический
- ✅ **API Routes** - можно проксировать запросы к Rails
- ✅ **ISR (Incremental Static Regeneration)** - обновление статических страниц
- ✅ **Актуальное решение** - соответствует требованиям 2025

### Недостатки
- ⚠️ **Миграция** - нужно переписать фронтенд на Next.js
- ⚠️ **Node.js сервер** - нужен для SSR (или Vercel/Netlify)
- ⚠️ **Два сервера** - Next.js + Rails API

### Установка

```bash
# Создание Next.js проекта
npx create-next-app@latest ikea-frontend --typescript --app

# Установка зависимостей
cd ikea-frontend
npm install axios react-helmet-async
```

### Пример реализации

```typescript
// app/products/[sku]/page.tsx (Next.js 13+ App Router)
import { Metadata } from 'next'
import { notFound } from 'next/navigation'

async function getProduct(sku: string) {
  const res = await fetch(`http://rails-api.com/api/v1/products/${sku}`, {
    cache: 'no-store' // или 'revalidate' для ISR
  })
  if (!res.ok) notFound()
  return res.json()
}

export async function generateMetadata({ params }: { params: { sku: string } }): Promise<Metadata> {
  const product = await getProduct(params.sku)
  
  return {
    title: `${product.data.name} - IKEA`,
    description: product.data.description?.substring(0, 160),
    openGraph: {
      title: product.data.name,
      description: product.data.description?.substring(0, 160),
      images: [product.data.images?.[0]],
      type: 'product',
      url: `https://your-domain.com/products/${params.sku}`
    },
    twitter: {
      card: 'summary_large_image',
      title: product.data.name,
      description: product.data.description?.substring(0, 160),
      images: [product.data.images?.[0]]
    }
  }
}

export default async function ProductPage({ params }: { params: { sku: string } }) {
  const product = await getProduct(params.sku)
  
  const jsonLd = {
    '@context': 'https://schema.org',
    '@type': 'Product',
    name: product.data.name,
    description: product.data.description,
    sku: product.data.sku,
    image: product.data.images,
    offers: {
      '@type': 'Offer',
      price: product.data.price,
      priceCurrency: 'BYN',
      availability: 'https://schema.org/InStock'
    },
    brand: {
      '@type': 'Brand',
      name: 'IKEA'
    }
  }
  
  return (
    <>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
      />
      <article>
        <h1>{product.data.name}</h1>
        <p>{product.data.description}</p>
        {/* Остальной контент */}
      </article>
    </>
  )
}
```

### Генерация sitemap.xml

```typescript
// app/sitemap.ts
import { MetadataRoute } from 'next'

export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  // Получаем список товаров из Rails API
  const products = await fetch('http://rails-api.com/api/v1/products?per_page=10000')
    .then(res => res.json())
  
  return [
    {
      url: 'https://your-domain.com',
      lastModified: new Date(),
      changeFrequency: 'daily',
      priority: 1,
    },
    ...products.data.map((product: any) => ({
      url: `https://your-domain.com/products/${product.sku}`,
      lastModified: new Date(product.updated_at),
      changeFrequency: 'weekly',
      priority: 0.8,
    })),
  ]
}
```

### robots.txt

```typescript
// app/robots.ts
import { MetadataRoute } from 'next'

export default function robots(): MetadataRoute.Robots {
  return {
    rules: {
      userAgent: '*',
      allow: '/',
      disallow: ['/api/', '/admin/'],
    },
    sitemap: 'https://your-domain.com/sitemap.xml',
  }
}
```

### Деплой

```bash
# Vercel (рекомендуется)
vercel deploy

# Или собственный сервер
npm run build
npm start
```

### Оценка
- **Сложность внедрения**: ⭐⭐⭐⭐ (высокая - миграция)
- **SEO-оптимизация**: ⭐⭐⭐⭐⭐ (отличная)
- **Производительность**: ⭐⭐⭐⭐⭐ (отличная)
- **Актуальность 2025**: ⭐⭐⭐⭐⭐ (самое актуальное)

---

## 🎨 Вариант 2: React Helmet + Prerender.io (Без миграции)

### Описание
Оставить существующий React SPA, добавить React Helmet для meta-тегов и использовать Prerender.io для SSR.

### Архитектура
```
Поисковый бот → Prerender.io → React SPA → HTML (рендерится)
Пользователь → React SPA (обычный SPA)
     ↓
Rails API (остается как есть)
```

### Преимущества
- ✅ **Без миграции** - можно использовать существующий React код
- ✅ **Быстрое внедрение** - минимальные изменения
- ✅ **React Helmet** - управление meta-тегами
- ✅ **Работает с любым React SPA**

### Недостатки
- ⚠️ **Платный сервис** - Prerender.io от $99/мес
- ⚠️ **Зависимость** - если сервис недоступен, SEO не работает
- ⚠️ **Задержка** - первый рендер может быть медленным
- ⚠️ **Ограниченный контроль** - сложно настроить динамические meta-теги

### Установка

```bash
# React Helmet
npm install react-helmet-async

# Prerender.io (опционально - можно использовать self-hosted Rendertron)
```

### Пример реализации

```typescript
// components/ProductPage.tsx
import { Helmet } from 'react-helmet-async'
import { useEffect, useState } from 'react'
import axios from 'axios'

export function ProductPage({ sku }: { sku: string }) {
  const [product, setProduct] = useState(null)
  
  useEffect(() => {
    axios.get(`/api/v1/products/${sku}`)
      .then(res => setProduct(res.data))
  }, [sku])
  
  if (!product) return <div>Loading...</div>
  
  const jsonLd = {
    '@context': 'https://schema.org',
    '@type': 'Product',
    name: product.name,
    description: product.description,
    sku: product.sku,
    // ...
  }
  
  return (
    <>
      <Helmet>
        <title>{product.name} - IKEA</title>
        <meta name="description" content={product.description?.substring(0, 160)} />
        <meta property="og:title" content={product.name} />
        <meta property="og:description" content={product.description?.substring(0, 160)} />
        <meta property="og:image" content={product.images?.[0]} />
        <meta property="og:type" content="product" />
        <meta property="og:url" content={`https://your-domain.com/products/${sku}`} />
        <link rel="canonical" href={`https://your-domain.com/products/${sku}`} />
      </Helmet>
      
      <script type="application/ld+json">
        {JSON.stringify(jsonLd)}
      </script>
      
      <article>
        <h1>{product.name}</h1>
        {/* Остальной контент */}
      </article>
    </>
  )
}
```

### Настройка Prerender.io

```nginx
# Nginx конфигурация
server {
    location / {
        # Проверяем, является ли запрос от поискового бота
        if ($http_user_agent ~* "googlebot|bingbot|yandex|baiduspider") {
            proxy_pass http://prerender.io;
            break;
        }
        
        # Обычные пользователи получают React SPA
        try_files $uri $uri/ /index.html;
    }
}
```

### Оценка
- **Сложность внедрения**: ⭐⭐ (низкая)
- **SEO-оптимизация**: ⭐⭐⭐⭐ (хорошая)
- **Производительность**: ⭐⭐⭐ (средняя)
- **Актуальность 2025**: ⭐⭐⭐ (работает, но не идеально)

---

## ⚡ Вариант 3: Self-hosted Rendertron (Бесплатная альтернатива)

### Описание
Использовать self-hosted Rendertron (от Google) для рендеринга React SPA в HTML.

### Архитектура
```
Поисковый бот → Rendertron (Docker) → React SPA → HTML
Пользователь → React SPA (обычный SPA)
     ↓
Rails API (остается как есть)
```

### Преимущества
- ✅ **Бесплатно** - open-source решение от Google
- ✅ **Self-hosted** - полный контроль
- ✅ **Без миграции** - работает с существующим React SPA
- ✅ **Гибкость** - можно настроить под свои нужды

### Недостатки
- ⚠️ **Инфраструктура** - нужно поддерживать Docker контейнер
- ⚠️ **Ресурсы** - требует дополнительных ресурсов сервера
- ⚠️ **Настройка** - нужно настроить Nginx и Docker

### Установка

```dockerfile
# Dockerfile для Rendertron
FROM node:18
RUN npm install -g rendertron
EXPOSE 3000
CMD ["rendertron"]
```

```yaml
# docker-compose.yml
services:
  rendertron:
    build: .
    ports:
      - "3000:3000"
    environment:
      - RENDERTRON_URL=http://rendertron:3000
```

### Настройка Nginx

```nginx
# Проверка User-Agent и проксирование к Rendertron
map $http_user_agent $is_bot {
    default 0;
    ~*googlebot 1;
    ~*bingbot 1;
    ~*yandex 1;
    ~*baiduspider 1;
}

server {
    location / {
        if ($is_bot) {
            proxy_pass http://rendertron:3000/render?url=http://your-domain.com$request_uri;
            break;
        }
        
        try_files $uri $uri/ /index.html;
    }
}
```

### Оценка
- **Сложность внедрения**: ⭐⭐⭐ (средняя)
- **SEO-оптимизация**: ⭐⭐⭐⭐ (хорошая)
- **Производительность**: ⭐⭐⭐ (средняя)
- **Актуальность 2025**: ⭐⭐⭐⭐ (хорошая)

---

## 📊 Сравнительная таблица

| Критерий | Next.js SSR | Prerender.io | Self-hosted Rendertron |
|----------|-------------|--------------|------------------------|
| **Сложность внедрения** | ⭐⭐⭐⭐ | ⭐⭐ | ⭐⭐⭐ |
| **SEO-оптимизация** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐⭐ | ⭐⭐⭐⭐ |
| **Производительность** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐ |
| **Стоимость** | Бесплатно* | $99+/мес | Бесплатно |
| **Актуальность 2025** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐ |
| **Core Web Vitals** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐ |
| **Гибкость** | ⭐⭐⭐⭐⭐ | ⭐⭐⭐ | ⭐⭐⭐⭐ |
| **Поддержка** | Большое сообщество | Коммерческая | Google |

*Next.js бесплатен, но нужен хостинг (Vercel бесплатный план или свой сервер)

---

## 🎯 Рекомендация для IKEA API + React SPA

### Рекомендую: **Вариант 1 - Next.js (SSR/SSG)** ⭐

### Причины:

1. **Соответствие требованиям 2025**
   - Нативная поддержка SSR/SSG
   - Отличные Core Web Vitals
   - Автоматическая оптимизация

2. **Лучший SEO**
   - Полный HTML при первой загрузке
   - Динамические meta-теги
   - Структурированные данные в HTML

3. **Производительность**
   - Автоматическая оптимизация изображений
   - Code splitting
   - ISR для обновления контента

4. **Будущее**
   - Активно развивается
   - Большое сообщество
   - Поддержка от Vercel

### План миграции:

1. **Создать Next.js проект**
   ```bash
   npx create-next-app@latest ikea-frontend --typescript --app
   ```

2. **Мигрировать компоненты**
   - Перенести React компоненты
   - Адаптировать под Next.js App Router
   - Настроить API клиент для Rails

3. **Добавить SSR для публичных страниц**
   - `/products/[sku]` - с SSR
   - `/categories/[id]` - с SSR
   - Главная страница - с SSG

4. **Настроить meta-теги**
   - `generateMetadata` для каждой страницы
   - Open Graph теги
   - Twitter Cards

5. **Добавить структурированные данные**
   - JSON-LD для товаров
   - BreadcrumbList
   - Organization

6. **Создать sitemap.xml и robots.txt**
   - Динамическая генерация sitemap
   - Настройка robots.txt

7. **Оптимизация**
   - Image optimization
   - Code splitting
   - ISR для часто обновляемых страниц

---

## 🔧 Дополнительные инструменты для SEO (2025)

### 1. **React Helmet Async** (для meta-тегов)
```bash
npm install react-helmet-async
```

### 2. **Next-SEO** (для Next.js)
```bash
npm install next-seo
```

### 3. **Sitemap Generator** (для Rails API)
```ruby
# Gemfile
gem 'sitemap_generator'
```

### 4. **Structured Data Testing Tool**
- Google Rich Results Test: https://search.google.com/test/rich-results
- Schema.org Validator: https://validator.schema.org/

### 5. **Мониторинг**
- Google Search Console
- Google Analytics 4
- Core Web Vitals Report

---

## 📝 Пример полной реализации (Next.js)

### Структура проекта

```
ikea-frontend/
├── app/
│   ├── layout.tsx          # Root layout
│   ├── page.tsx             # Главная страница (SSG)
│   ├── products/
│   │   └── [sku]/
│   │       └── page.tsx     # Страница товара (SSR)
│   ├── categories/
│   │   └── [id]/
│   │       └── page.tsx     # Страница категории (SSR)
│   ├── sitemap.ts           # Динамический sitemap
│   └── robots.ts            # robots.txt
├── components/
│   ├── ProductCard.tsx
│   └── CategoryList.tsx
└── lib/
    └── api.ts               # Клиент для Rails API
```

### API клиент

```typescript
// lib/api.ts
const API_URL = process.env.NEXT_PUBLIC_API_URL || 'http://localhost:3000'

export async function getProduct(sku: string) {
  const res = await fetch(`${API_URL}/api/v1/products/${sku}`, {
    cache: 'no-store' // или 'revalidate' для ISR
  })
  if (!res.ok) throw new Error('Product not found')
  return res.json()
}

export async function getProducts(params?: {
  page?: number
  per_page?: number
  category_id?: string
}) {
  const query = new URLSearchParams(params as any)
  const res = await fetch(`${API_URL}/api/v1/products?${query}`)
  return res.json()
}
```

### Страница товара с SEO

```typescript
// app/products/[sku]/page.tsx
import { Metadata } from 'next'
import { notFound } from 'next/navigation'
import { getProduct } from '@/lib/api'

export async function generateMetadata({ params }: { params: { sku: string } }): Promise<Metadata> {
  try {
    const { data: product } = await getProduct(params.sku)
    
    return {
      title: `${product.name} - IKEA`,
      description: product.description?.substring(0, 160) || '',
      openGraph: {
        title: product.name,
        description: product.description?.substring(0, 160) || '',
        images: product.images || [],
        type: 'product',
        url: `https://your-domain.com/products/${params.sku}`,
      },
      twitter: {
        card: 'summary_large_image',
        title: product.name,
        description: product.description?.substring(0, 160) || '',
        images: product.images || [],
      },
      alternates: {
        canonical: `https://your-domain.com/products/${params.sku}`,
      },
    }
  } catch {
    return {
      title: 'Product Not Found',
    }
  }
}

export default async function ProductPage({ params }: { params: { sku: string } }) {
  const { data: product } = await getProduct(params.sku)
  
  const jsonLd = {
    '@context': 'https://schema.org',
    '@type': 'Product',
    name: product.name,
    description: product.description,
    sku: product.sku,
    image: product.images,
    offers: {
      '@type': 'Offer',
      price: product.price,
      priceCurrency: 'BYN',
      availability: 'https://schema.org/InStock',
      url: `https://your-domain.com/products/${product.sku}`,
    },
    brand: {
      '@type': 'Brand',
      name: 'IKEA',
    },
    category: product.category?.name,
  }
  
  return (
    <>
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
      />
      <article>
        <h1>{product.name}</h1>
        <p>{product.description}</p>
        <div className="product-images">
          {product.images?.map((image: string, index: number) => (
            <img key={index} src={image} alt={product.name} />
          ))}
        </div>
        <div className="product-price">
          <span>{product.price} BYN</span>
        </div>
      </article>
    </>
  )
}
```

### Динамический sitemap

```typescript
// app/sitemap.ts
import { MetadataRoute } from 'next'
import { getProducts } from '@/lib/api'

export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  const baseUrl = 'https://your-domain.com'
  
  // Получаем все товары (может потребоваться пагинация)
  const products = await getProducts({ per_page: 10000 })
  
  return [
    {
      url: baseUrl,
      lastModified: new Date(),
      changeFrequency: 'daily',
      priority: 1,
    },
    ...products.data.map((product: any) => ({
      url: `${baseUrl}/products/${product.sku}`,
      lastModified: new Date(product.updated_at),
      changeFrequency: 'weekly',
      priority: 0.8,
    })),
  ]
}
```

---

## 🚀 Деплой Next.js

### Вариант 1: Vercel (рекомендуется)

```bash
# Установка Vercel CLI
npm i -g vercel

# Деплой
vercel

# Настройка переменных окружения
vercel env add NEXT_PUBLIC_API_URL
```

### Вариант 2: Собственный сервер

```bash
# Сборка
npm run build

# Запуск production сервера
npm start
```

### Docker

```dockerfile
FROM node:18-alpine AS builder
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY . .
RUN npm run build

FROM node:18-alpine AS runner
WORKDIR /app
ENV NODE_ENV production
COPY --from=builder /app/public ./public
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
EXPOSE 3000
CMD ["node", "server.js"]
```

---

## ✅ Чеклист SEO для 2025 года

### Технические требования
- [ ] Server-Side Rendering (SSR) для публичных страниц
- [ ] Meta-теги (title, description, og:tags) в HTML
- [ ] Структурированные данные (JSON-LD) в HTML
- [ ] Sitemap.xml (динамическая генерация)
- [ ] Robots.txt
- [ ] Canonical URLs
- [ ] Mobile-friendly (responsive design)

### Производительность
- [ ] Core Web Vitals (LCP < 2.5s, FID < 100ms, CLS < 0.1)
- [ ] Оптимизация изображений (WebP, AVIF)
- [ ] Code splitting
- [ ] Lazy loading
- [ ] Минификация и сжатие

### Контент
- [ ] Уникальные title и description для каждой страницы
- [ ] Alt-теги для всех изображений
- [ ] Семантическая HTML разметка
- [ ] Breadcrumbs для навигации

### Мониторинг
- [ ] Google Search Console
- [ ] Google Analytics 4
- [ ] Core Web Vitals мониторинг

---

## 📚 Полезные ресурсы

- [Next.js Documentation](https://nextjs.org/docs)
- [Google Search Central](https://developers.google.com/search)
- [Schema.org](https://schema.org/)
- [Core Web Vitals](https://web.dev/vitals/)
- [Google Rich Results Test](https://search.google.com/test/rich-results)

---

**Готов помочь с внедрением Next.js для вашего проекта!** 🎉
