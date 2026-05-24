# Full stack migration + frontend CI/CD

Этот документ покрывает перенос между серверами:
- frontend
- backend
- Nginx / Nginx Proxy Manager data
- PM2
- PostgreSQL (структура, роли, данные)

И настройку CI/CD для фронта через GitHub Actions.

## 1) Миграционный скрипт

Скрипт: `scripts/migrate_full_stack.sh`

### Что делает
1. На source-сервере делает:
   - `pg_dumpall --globals-only`
   - `pg_dump -Fc` нужной БД
   - архивы директорий frontend/backend/NPM/PM2/nginx sites
2. Копирует артефакты через локальную машину на target.
3. На target:
   - делает backup текущих директорий
   - разворачивает архивы
   - восстанавливает PostgreSQL
   - перезапускает сервисы
4. Выполняет базовые проверки.

### Обязательные переменные
- `SOURCE_HOST`
- `TARGET_HOST`
- `DB_NAME`

### Пример запуска

```bash
chmod +x scripts/migrate_full_stack.sh

SOURCE_HOST=45.135.234.22 \
TARGET_HOST=11.22.33.44 \
SOURCE_USER=deploy \
TARGET_USER=deploy \
DB_NAME=ikea_production \
FRONTEND_DIR=/var/www/ikea_frontend \
BACKEND_DIR=/home/deploy/apps/ikea_back \
NPM_DATA_DIR=/opt/nginx-proxy-manager \
RESTART_BACK_CMD="sudo systemctl restart ikea_api" \
RESTART_FRONT_CMD="sudo systemctl reload nginx" \
RESTART_PM2_CMD="pm2 resurrect" \
./scripts/migrate_full_stack.sh
```

### Важные замечания
- Перед запуском проверьте SSH-доступ с локальной машины на source и target.
- Нужен доступ `sudo` на серверах (для `/etc/nginx`, PostgreSQL и системных директорий).
- После миграции обязательно выполните smoke-тест:
  - frontend URL
  - backend `/api/...`
  - admin `/admin`
  - docs `/api-docs`

## 2) CI/CD фронта

Workflow: `.github/workflows/frontend-cicd.yml`

Триггеры:
- push в `main` при изменениях в `frontend/**`
- ручной запуск (`workflow_dispatch`)

Этапы:
1. `npm ci`
2. `npm test`
3. `npm run build`
4. `rsync dist` на сервер
5. удаленный reload/restart

### GitHub Secrets
Добавьте в repository secrets:
- `FRONT_SSH_PRIVATE_KEY` — приватный ключ для доступа к серверу
- `FRONT_SSH_USER` — SSH user
- `FRONT_SSH_HOST` — SSH host/IP
- `FRONT_DEPLOY_PATH` — куда выкладывать `dist` (например `/var/www/ikea_frontend/dist`)
- `FRONT_RELOAD_CMD` — команда перезапуска (например `sudo systemctl reload nginx` или `pm2 restart ikea_front`)

### Важное по структуре
Workflow ожидает фронт в `frontend/`. Если у вас другой путь, поменяйте:
- `on.push.paths`
- `defaults.run.working-directory`
- путь `./dist/` в `rsync`
