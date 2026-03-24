Патч добавляет адаптер для плоского формата results.jsonl и встраивает его в существующий ImportExtendedAttributesFromFileJob.

Что добавлено:
- app/services/products/import_payload_adapter.rb
- обновлен app/services/products/extended_attributes_import_service.rb
- обновлен app/jobs/import_extended_attributes_from_file_job.rb
- добавлен lib/tasks/products_results_import.rake

Что умеет адаптер:
- автоматически распознает results.jsonl
- преобразует плоский payload в формат, который уже понимает ExtendedAttributesImportService
- фильтрует breadcrumb-категории до нормальных category ids (не создает мусорный category id `products`)
- использует trusted images для results.jsonl, чтобы не делать HEAD на все картинки
- переносит основные поля: sku, price, category_id, categories, images, product_url, short_description,
  Полное описание, Описание, Полезная информация, Материал и уход, Безопасность, variants, related_products

Как запускать:
1) Через новую rake-задачу
   bundle exec rake products:import_results_jsonl[/absolute/path/to/results.jsonl,true]

2) Или через существующий ParserTask / админку, если в payload добавить:
   format: 'results_jsonl'
   trust_images: true

Замечание:
- fallback-имя для новых товаров берется из product_url, если в файле нет явного title/name.
