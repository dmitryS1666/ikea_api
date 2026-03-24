# Патч вкладки «Фильтры» для categories_admin.rb

Файлы:
- `categories_admin_filters_patch.diff`
- `README_categories_admin_filters_patch.md`

## Что добавляет патч
- новые routes:
  - `add_filter_value`
  - `update_filter_value`
  - `remove_filter_value`
- controller actions для CRUD фильтров категории
- новую вкладку `tab :filters, label: "Фильтры"`

## Как применить
Из корня проекта:

```bash
git apply /path/to/categories_admin_filters_patch.diff
```

Если `git apply` не проходит из-за различий в файле, открой diff и внеси изменения вручную в:

`app/admin/categories_admin.rb`

## Что проверить после применения
1. Открыть карточку категории в админке.
2. Убедиться, что появилась вкладка `Фильтры`.
3. Проверить:
   - добавление новой строки фильтра
   - редактирование существующей строки
   - удаление строки
4. Убедиться, что фильтры показываются только для текущей категории.

## Важное ограничение
Патч работает через динамическую проверку колонок `ProductFilterValue.column_names`, поэтому не требует жёстко зашитой схемы. Но если у вас нестандартные поля фильтров, список editable-полей можно расширить прямо в `editable_columns`.
