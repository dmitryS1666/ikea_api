# Runbook: приведение каталога на проде к эталонному виду

Ниже только те действия и команды, которые уже использовались в проекте.

## 1. Обновить иерархию каталога по эталонному JSON

### Залить JSON-файл на сервер
```bash
scp /home/sushi/Documents/ikea_api/ikeya_categories_merged_into_target_without_losing_ikea_ids.json user@PROD_HOST:/tmp/
```

### Зайти на сервер
```bash
ssh user@PROD_HOST
cd /path/to/app/current
```

### Проверить, что таски доступны
```bash
RAILS_ENV=production bundle exec rake -T | grep category_hierarchy
```

### Dry-run
```bash
RAILS_ENV=production bundle exec rake "category_hierarchy:dry_run[/tmp/ikeya_categories_merged_into_target_without_losing_ikea_ids.json]"
```

### Посмотреть последний отчёт
```bash
REPORT=$(ls -t tmp/category_hierarchy_import/*.json | head -1)
jq '{validations, stats, warnings, errors, applied}' "$REPORT"
```

### Apply
```bash
RAILS_ENV=production bundle exec rake "category_hierarchy:apply[/tmp/ikeya_categories_merged_into_target_without_losing_ikea_ids.json]" CONFIRM=YES SOFT_DELETE_MISSING=false PURGE_DELETED_ASSETS=false
```

### Проверить итоговый отчёт
```bash
REPORT=$(ls -t tmp/category_hierarchy_import/*.json | head -1)
jq '{validations, stats, warnings, errors, applied}' "$REPORT"
```

Ожидаемо:
- `errors: []`
- `applied: true`

---

## 2. Если нужно вернуть `translated_name` под названия файлов иконок

### Preview
```bash
RAILS_ENV=production bundle exec rake categories:align_translated_names_to_icon_names
```

### Apply
```bash
RAILS_ENV=production bundle exec rake categories:align_translated_names_to_icon_names CONFIRM=YES
```

---

## 3. Загрузка иконок для категорий

В проекте используется таск `categories:assign_icons`.

### Проверить `.png` с двойными пробелами
```bash
RAILS_ENV=production bundle exec rake "categories:report_icon_png_double_spaces[/path/to/icons]"
```

### Назначить иконки из папки
```bash
RAILS_ENV=production bundle exec rake "categories:assign_icons[/path/to/icons]"
```

> Этот таск прикрепляет `icon` по имени файла и найденной категории.

---

## 4. Пиктограммы для категорий 1-го уровня

Отдельного автоматического rake-task для массовой загрузки `pictogram` в проекте нет.

Текущее состояние:
- `pictogram` загружается вручную через админку категории.

---

## 5. Очистка кэша на проде

### Полная очистка кэша
```bash
RAILS_ENV=production bundle exec rails runner "Rails.cache.clear"
```

### Очистка только category-related cache
```bash
RAILS_ENV=production bundle exec rails runner '
Rails.cache.delete_matched("categories_tree_*") if Rails.cache.respond_to?(:delete_matched)
Rails.cache.delete("categories_product_counts")
Rails.cache.delete("categories_children_counts")
Rails.cache.delete("categories_max_updated_at")
Rails.cache.delete("categories_tree_json")
Rails.cache.delete("categories_map_json")
'
```

### Очистка счётчиков детей по категориям
```bash
RAILS_ENV=production bundle exec rails runner '
Category.unscoped.pluck(:ikea_id).each do |ikea_id|
  Rails.cache.delete("category_#{ikea_id}_children_count")
end
'
```

---

## 6. Минимальная последовательность для прода

```bash
scp /home/sushi/Documents/ikea_api/ikeya_categories_merged_into_target_without_losing_ikea_ids.json user@PROD_HOST:/tmp/

ssh user@PROD_HOST
cd /path/to/app/current

RAILS_ENV=production bundle exec rake "category_hierarchy:dry_run[/tmp/ikeya_categories_merged_into_target_without_losing_ikea_ids.json]"

REPORT=$(ls -t tmp/category_hierarchy_import/*.json | head -1)
jq '{validations, stats, warnings, errors, applied}' "$REPORT"

RAILS_ENV=production bundle exec rake "category_hierarchy:apply[/tmp/ikeya_categories_merged_into_target_without_losing_ikea_ids.json]" CONFIRM=YES SOFT_DELETE_MISSING=false PURGE_DELETED_ASSETS=false

RAILS_ENV=production bundle exec rails runner "Rails.cache.clear"
```
