# Дозагрузка оплаченных заказов сентября 2026

Дополнительный патч применяется после основного Poland-патча и test_fix_01.
Новых миграций в дополнении нет. Проверенный ранее результат 67/0 относится
к предыдущей версии; новые сценарии требуют отдельного локального прогона.

## Выборка

`BackfillPolandTrackExportsJob` выбирает платежи в интервале
`[max(AS_OF − 21 день, 01.09.2026 00:00), min(AS_OF, 01.10.2026 00:00))`
по времени Europe/Minsk. AS_OF обязательно передаётся джобе явно и сохраняется
при повторном выполнении Sidekiq. В rake-команде по умолчанию берётся время запуска.

Для `AS_OF=2026-09-27T14:08:17+03:00` окно начинается
`2026-09-06T14:08:17+03:00` и заканчивается перед `2026-09-27T14:08:17+03:00`.
Август, октябрь и другие годы не включаются. В начале сентября берётся только
прошедшая часть сентября. Дата создания заказа не используется для отбора.

Подтверждение даты оплаты: `webpay_paid_at`, а при его отсутствии — самый ранний
`OrderStatusEvent` с `to_status=paid`. `updated_at` и `purchased_at` не подставляются
вместо даты оплаты. Заказы без обоих доказательств даты не выбираются.
Учитываются paid и последующие статусы, включая completed. Не выбираются черновики,
отменённые, неоплаченные и заказы с `FinanceEntry.payment_status=refunded`.

## Запуск

Сначала тесты из корня проекта:

```bash
bash bin/test-poland-tracks
```

Сухой прогон на сервере, из `/home/deploy/apps/ikea_back/current`:

```bash
AS_OF='2026-09-27T14:08:17+03:00' RAILS_ENV=production bundle exec rake poland_tracks:backfill_september
```

Он не записывает задания/заказы/позиции и не ставит фоновые задачи. В отчёте:

| result | Значение |
| --- | --- |
| ready | Данных достаточно; при RUN=true будет создано pending-задание |
| waiting_track | Данные корректны, но для типов 1/4 нет трека Европочты |
| blocked | Отсутствуют/некорректны паспорт, прописка, цена PLN, URL, адрес или иные обязательные поля |
| existing | Уже есть экспорт любого состояния; он останется без изменений |
| unsupported_delivery | Неизвестный способ доставки |
| no_longer_eligible | В реальном прогоне заказ перестал подходить до получения блокировки |

`existing` не означает, что трек уже успешно создан: смотреть поле state.
Итог содержит максимум 500 подробных строк; counts/examined считают весь прогон,
а все строки с ID/результатом пишутся в Rails log без паспортных данных и тела запроса.

После проверки отчёта, сначала небольшой пакет:

```bash
AS_OF='2026-09-27T14:08:17+03:00' RUN=true LIMIT=5 RAILS_ENV=production bundle exec rake poland_tracks:backfill_september
```

Затем весь тот же интервал:

```bash
AS_OF='2026-09-27T14:08:17+03:00' RUN=true RAILS_ENV=production bundle exec rake poland_tracks:backfill_september
```

Лимит применяется к просмотренным подходящим заказам, включая existing/blocked,
в порядке ID. Для полного второго прогона LIMIT убрать. Реальный прогон требует
`POLAND_TRACKS_ENABLED=true` и API-ключ в окружении Rails/Sidekiq.

Фоновый вариант через Rails console:

```ruby
BackfillPolandTrackExportsJob.perform_later(as_of: "2026-09-27T14:08:17+03:00", dry_run: false)
```

Джоба не делает POST сама: создаёт задание и передаёт его штатному PolandTrackExportJob.
Защита от повторов — блокировка заказа плюс уникальный индекс по order_id.
Существующие succeeded/sending/uncertain/blocked/pending не сбрасываются.
Никаких автоматических созданий новых отправлений Европочты для старых заказов нет.
Возврат денег повторно проверяется непосредственно перед Poland-отправкой.
Запуск вручную, без добавления периодического расписания.

## Патч weight для сентябрьских снимков

После выкладки поля `weight` уже созданные сентябрьские exports могут не содержать
его в `payload_json`. Сухой прогон:

```bash
AS_OF='2026-09-27T14:08:17+03:00' RAILS_ENV=production bundle exec rake poland_tracks:patch_weight_september
```

Реальная запись только для `pending`/`blocked` (blocked переводится в pending и
ставится в очередь). `succeeded` не трогаются: у create API нет безопасного
обновления уже принятых треков. `sending`/`uncertain` пропускаются до сверки.

```bash
AS_OF='2026-09-27T14:08:17+03:00' RUN=true LIMIT=5 RAILS_ENV=production bundle exec rake poland_tracks:patch_weight_september
AS_OF='2026-09-27T14:08:17+03:00' RUN=true RAILS_ENV=production bundle exec rake poland_tracks:patch_weight_september
```

Даже без этого rake pending-снимки без `weight` дополняются из заказа в момент
отправки (`Payload.for_export`).

## Нехватка исторических данных

Для старых позиций `poland_price_pln` и `poland_product_url` могут быть пустыми.
Реальный прогон создаёт для таких заказов blocked-задания, доступные в админке.
Восстановить проверенные PLN/URL из исходного заказа и выполнить
`poland_tracks:retry[ID]`, как в README_POLAND_TRACKS.md. Повторная backfill-джоба
не меняет blocked самостоятельно. Используется профиль получателя на момент
backfill: исторического снимка получателя до установки интеграции в проекте нет.

Если запись была создана в ShopByShop вне этой интеграции, локальный журнал о ней
не знает. API поиска/идемпотентности не предоставлен — такие заказы нужно сверить
до отправки. Повторы собственного экспорта защищены локальным журналом.

## Коммит только изменений этой интеграции

Файл `ikeya_poland_tracks_complete.patch` — совокупный патч относительно исходного
ZIP: основной функционал, test_fix_01 и backfill. После применения дополнения к
рабочим файлам не применять complete ещё раз к рабочему дереву. Его можно применить
только к индексу Git для точного отбора изменений, как ниже.

Следующий блок предназначен для запуска в bash из рабочего репозитория. Он
останавливается при уже подготовленных чужих изменениях, отличии HEAD от origin/main,
ошибке тестов, несовпадении контекста или дополнительных правках в затронутых файлах.
Ничего не сбрасывает и не использует force push. При остановке прислать вывод.

```bash
(
  set -euo pipefail
  poland_patch="$HOME/Downloads/ikeya_poland_tracks_complete.patch"
  test -f "$poland_patch"
  test "$(git branch --show-current)" = main
  git diff --cached --quiet
  git fetch origin main
  test "$(git rev-parse HEAD)" = "$(git rev-parse origin/main)"
  bash bin/test-poland-tracks
  git apply --cached --check "$poland_patch"
  git apply --cached "$poland_patch"
  git diff --cached --check
  mapfile -t poland_files < <(git diff --cached --name-only)
  git diff --quiet -- "${poland_files[@]}"
  git diff --cached --stat
  git commit -m "Add paid order Poland exports and September backfill"
  poland_commit="$(git rev-parse HEAD)"
  git push origin HEAD:main
  printf 'POLAND_DEPLOY_REF=%s\n' "$poland_commit"
)
```

`.env` и ключи не входят в совокупный патч. Чужие правки в незатронутых файлах
остаются в рабочем дереве. Общий db/schema.rb не включён: миграции присутствуют,
генерацию/частичное включение схемы надо рассматривать отдельно, если в ней есть
другие локальные изменения. Если индекс уже содержит часть этой интеграции или
HEAD уже включает её коммит, `--cached --check` остановится; не обходить это
через `git add .`, сначала посмотреть фактическое состояние.

## Деплой выбранного коммита

В config/deploy.rb добавлен DEPLOY_REF с прежним fallback на main. Это позволяет
развернуть именно выбранный SHA, даже если main позже изменится.

```bash
DEPLOY_REF=<SHA_из_POLAND_DEPLOY_REF> bundle exec cap production deploy
```

Текущий production-конфиг проекта: `deploy@185.47.153.112`, SSH порт 2200,
ключ `~/.ssh/ikea_front_prod_github_actions`, каталог `/home/deploy/apps/ikea_back`.
Стандартный Capistrano-процесс выполняет миграции, затем существующий db:seed
и перезапуски Puma/Sidekiq. `.env` берётся из shared: локальные значения туда
автоматически не переносятся. Backfill после деплоя автоматически не запускается.

Проверка на сервере:

```bash
ssh -p 2200 -i ~/.ssh/ikea_front_prod_github_actions deploy@185.47.153.112
cd /home/deploy/apps/ikea_back/current
cat REVISION
sudo systemctl is-active ikea_back_puma ikea_back_sidekiq
export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
RAILS_ENV=production bundle exec rails runner 'puts({enabled: PolandTrackExport.enabled?, key_present: ENV["POLAND_TRACKS_API_KEY"].present?, schedule_enabled: CronSchedule.find_by(task_type: "poland_track_exports")&.enabled?}.to_json)'
```

REVISION должен совпасть с выбранным SHA; оба сервиса — active. Затем выполнить
сухой backfill и посмотреть отчёт перед RUN=true. На момент подготовки этого
патча коммит в рабочем репозитории пользователя, пуш и прод-деплой не выполнялись:
GitHub-коннектор не подключён, SSH-ключ и Ruby/Bundler в среде подготовки отсутствуют.
