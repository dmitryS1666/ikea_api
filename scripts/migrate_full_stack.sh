#!/usr/bin/env bash

set -euo pipefail

# Full stack migration script:
# - frontend files
# - backend files
# - nginx / Nginx Proxy Manager config and data
# - PM2 data
# - PostgreSQL database dump and restore
#
# Usage:
#   ./scripts/migrate_full_stack.sh
#   SOURCE_HOST=1.2.3.4 TARGET_HOST=5.6.7.8 DB_NAME=ikea_production ./scripts/migrate_full_stack.sh

timestamp="$(date +%Y%m%d_%H%M%S)"
work_dir="${WORK_DIR:-/tmp/ikea_migration_${timestamp}}"

SOURCE_HOST="${SOURCE_HOST:-}"
SOURCE_USER="${SOURCE_USER:-deploy}"
TARGET_HOST="${TARGET_HOST:-}"
TARGET_USER="${TARGET_USER:-deploy}"

DB_NAME="${DB_NAME:-}"
DB_USER="${DB_USER:-postgres}"

FRONTEND_DIR="${FRONTEND_DIR:-/var/www/ikea_frontend}"
BACKEND_DIR="${BACKEND_DIR:-/home/deploy/apps/ikea_back}"
NPM_DATA_DIR="${NPM_DATA_DIR:-/opt/nginx-proxy-manager}"
PM2_HOME_DIR="${PM2_HOME_DIR:-/home/${TARGET_USER}/.pm2}"
NGINX_SITES_AVAILABLE="${NGINX_SITES_AVAILABLE:-/etc/nginx/sites-available}"
NGINX_SITES_ENABLED="${NGINX_SITES_ENABLED:-/etc/nginx/sites-enabled}"

RESTART_FRONT_CMD="${RESTART_FRONT_CMD:-sudo systemctl reload nginx}"
RESTART_BACK_CMD="${RESTART_BACK_CMD:-sudo systemctl restart puma || true}"
RESTART_PM2_CMD="${RESTART_PM2_CMD:-pm2 resurrect || true}"

require_var() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    echo "ERROR: ${name} is required."
    exit 1
  fi
}

log() {
  echo
  echo "==> $1"
}

remote() {
  local user="$1"
  local host="$2"
  local cmd="$3"
  ssh -o StrictHostKeyChecking=accept-new "${user}@${host}" "$cmd"
}

copy_from_source() {
  local remote_path="$1"
  local local_path="$2"
  scp -o StrictHostKeyChecking=accept-new "${SOURCE_USER}@${SOURCE_HOST}:${remote_path}" "${local_path}"
}

copy_to_target() {
  local local_path="$1"
  local remote_path="$2"
  scp -o StrictHostKeyChecking=accept-new "${local_path}" "${TARGET_USER}@${TARGET_HOST}:${remote_path}"
}

require_var "SOURCE_HOST" "$SOURCE_HOST"
require_var "TARGET_HOST" "$TARGET_HOST"
require_var "DB_NAME" "$DB_NAME"

mkdir -p "$work_dir"/{source,target}

log "Preflight checks on source and target"
remote "$SOURCE_USER" "$SOURCE_HOST" "command -v pg_dump >/dev/null && command -v tar >/dev/null"
remote "$TARGET_USER" "$TARGET_HOST" "command -v pg_restore >/dev/null && command -v tar >/dev/null"

log "Create source backups (postgres + app/config data)"
remote "$SOURCE_USER" "$SOURCE_HOST" "
  set -euo pipefail
  mkdir -p /tmp/ikea_migration_${timestamp}
  sudo -u postgres pg_dumpall --globals-only > /tmp/ikea_migration_${timestamp}/globals.sql
  sudo -u postgres pg_dump -Fc '${DB_NAME}' > /tmp/ikea_migration_${timestamp}/${DB_NAME}.dump
  sudo tar -czf /tmp/ikea_migration_${timestamp}/frontend.tar.gz '${FRONTEND_DIR}'
  sudo tar -czf /tmp/ikea_migration_${timestamp}/backend.tar.gz '${BACKEND_DIR}'
  sudo tar -czf /tmp/ikea_migration_${timestamp}/npm_data.tar.gz '${NPM_DATA_DIR}'
  sudo tar -czf /tmp/ikea_migration_${timestamp}/pm2_data.tar.gz '/home/${SOURCE_USER}/.pm2'
  sudo tar -czf /tmp/ikea_migration_${timestamp}/nginx_sites.tar.gz '${NGINX_SITES_AVAILABLE}' '${NGINX_SITES_ENABLED}'
  sudo chown -R ${SOURCE_USER}:${SOURCE_USER} /tmp/ikea_migration_${timestamp}
"

log "Copy backup artifacts from source to local machine"
copy_from_source "/tmp/ikea_migration_${timestamp}/globals.sql" "$work_dir/source/globals.sql"
copy_from_source "/tmp/ikea_migration_${timestamp}/${DB_NAME}.dump" "$work_dir/source/${DB_NAME}.dump"
copy_from_source "/tmp/ikea_migration_${timestamp}/frontend.tar.gz" "$work_dir/source/frontend.tar.gz"
copy_from_source "/tmp/ikea_migration_${timestamp}/backend.tar.gz" "$work_dir/source/backend.tar.gz"
copy_from_source "/tmp/ikea_migration_${timestamp}/npm_data.tar.gz" "$work_dir/source/npm_data.tar.gz"
copy_from_source "/tmp/ikea_migration_${timestamp}/pm2_data.tar.gz" "$work_dir/source/pm2_data.tar.gz"
copy_from_source "/tmp/ikea_migration_${timestamp}/nginx_sites.tar.gz" "$work_dir/source/nginx_sites.tar.gz"

log "Upload artifacts to target"
remote "$TARGET_USER" "$TARGET_HOST" "mkdir -p /tmp/ikea_migration_${timestamp}"
copy_to_target "$work_dir/source/globals.sql" "/tmp/ikea_migration_${timestamp}/globals.sql"
copy_to_target "$work_dir/source/${DB_NAME}.dump" "/tmp/ikea_migration_${timestamp}/${DB_NAME}.dump"
copy_to_target "$work_dir/source/frontend.tar.gz" "/tmp/ikea_migration_${timestamp}/frontend.tar.gz"
copy_to_target "$work_dir/source/backend.tar.gz" "/tmp/ikea_migration_${timestamp}/backend.tar.gz"
copy_to_target "$work_dir/source/npm_data.tar.gz" "/tmp/ikea_migration_${timestamp}/npm_data.tar.gz"
copy_to_target "$work_dir/source/pm2_data.tar.gz" "/tmp/ikea_migration_${timestamp}/pm2_data.tar.gz"
copy_to_target "$work_dir/source/nginx_sites.tar.gz" "/tmp/ikea_migration_${timestamp}/nginx_sites.tar.gz"

log "Restore files and database on target"
remote "$TARGET_USER" "$TARGET_HOST" "
  set -euo pipefail

  backup_root='/tmp/ikea_target_backup_${timestamp}'
  sudo mkdir -p \"\$backup_root\"

  if [[ -d '${FRONTEND_DIR}' ]]; then
    sudo mv '${FRONTEND_DIR}' \"\${backup_root}/frontend\"
  fi
  if [[ -d '${BACKEND_DIR}' ]]; then
    sudo mv '${BACKEND_DIR}' \"\${backup_root}/backend\"
  fi
  if [[ -d '${NPM_DATA_DIR}' ]]; then
    sudo mv '${NPM_DATA_DIR}' \"\${backup_root}/npm_data\"
  fi
  if [[ -d '/home/${TARGET_USER}/.pm2' ]]; then
    sudo mv '/home/${TARGET_USER}/.pm2' \"\${backup_root}/pm2_data\"
  fi

  sudo tar -xzf /tmp/ikea_migration_${timestamp}/frontend.tar.gz -C /
  sudo tar -xzf /tmp/ikea_migration_${timestamp}/backend.tar.gz -C /
  sudo tar -xzf /tmp/ikea_migration_${timestamp}/npm_data.tar.gz -C /
  sudo tar -xzf /tmp/ikea_migration_${timestamp}/pm2_data.tar.gz -C /
  sudo tar -xzf /tmp/ikea_migration_${timestamp}/nginx_sites.tar.gz -C /

  sudo chown -R ${TARGET_USER}:${TARGET_USER} '${BACKEND_DIR}' '${FRONTEND_DIR}' '/home/${TARGET_USER}/.pm2' || true

  sudo -u postgres psql -f /tmp/ikea_migration_${timestamp}/globals.sql
  sudo -u postgres psql -tc \"SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'\" | grep -q 1 || sudo -u postgres createdb '${DB_NAME}'
  sudo -u postgres pg_restore --clean --if-exists --no-owner --dbname='${DB_NAME}' /tmp/ikea_migration_${timestamp}/${DB_NAME}.dump
"

log "Restart services on target"
remote "$TARGET_USER" "$TARGET_HOST" "
  set -euo pipefail
  ${RESTART_PM2_CMD}
  ${RESTART_BACK_CMD}
  ${RESTART_FRONT_CMD}
  sudo nginx -t
"

log "Post-migration checks"
remote "$TARGET_USER" "$TARGET_HOST" "
  set -euo pipefail
  systemctl is-active nginx >/dev/null && echo 'nginx: active'
  pm2 list || true
  sudo -u postgres psql -d '${DB_NAME}' -c 'SELECT NOW();' >/dev/null && echo 'postgres: ok'
"

log "Migration completed"
echo "Artifacts kept in: ${work_dir}"
echo "Source server temp: /tmp/ikea_migration_${timestamp}"
echo "Target server temp: /tmp/ikea_migration_${timestamp}"
echo "Recommendation: run smoke tests for frontend, backend API, and admin paths."
