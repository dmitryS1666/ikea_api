# Финальный патч для merge категорий в Trestle

## Что добавляет патч

- merge категории через интерфейс Trestle;
- merge выполняется как `source -> target`;
- target можно указать по `ikea_id` или по точному имени категории;
- переносятся основные связи: `products.category_id`, `category_products`, `product_filter_values`, баннеры, promo links, article-category links и ссылки в `content_articles.body_blocks`;
- дети source-подветки перепривязываются под target-подветку;
- source категория переводится в `is_deleted=true`;
- после merge чистится кэш дерева.

## Файлы в архиве

- `app/admin/categories_admin.rb`
- `app/services/categories/merge_service.rb`
- `app/views/trestle/categories/index.html.erb`
- `app/views/trestle/categories/_category_node.html.erb`
- `app/views/trestle/categories/_tree_drag_drop_assets.html.erb`

## Как пользоваться

1. Распаковать архив в проект.
2. Перезапустить приложение.
3. Очистить кэш:

```bash
RAILS_ENV=production bundle exec rails runner "Rails.cache.clear"
```

4. На странице категорий нажать кнопку merge (`<->` / иконка compress) у нужной source-категории.
5. Ввести `ikea_id` категории назначения. Если `ikea_id` не знаешь, можно ввести **точное имя** категории, но только если оно уникально.
6. Подтвердить merge.

## Что проверять после merge

- source категория стала `is_deleted=true`;
- продукты source переехали в target;
- дочерние категории source теперь лежат под target;
- дерево открывается без дубликатов и циклов;
- страницы категорий и фильтры не упали.

## Важные ограничения

- нельзя merge category в саму себя;
- нельзя merge category в собственного потомка;
- нельзя merge в отключенную (`is_deleted`) категорию;
- merge не меняет `ikea_id` target-категории;
- source категория не удаляется физически, только помечается как отключенная.

## Рекомендация

Перед продом сначала проверить merge на staging на 2-3 тестовых категориях:
- leaf category;
- category с детьми;
- category с привязанными товарами.
