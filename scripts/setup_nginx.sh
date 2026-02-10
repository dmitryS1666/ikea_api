#!/bin/bash
# Скрипт для настройки Nginx на сервере
# Использование: ./scripts/setup_nginx.sh

set -e

SERVER_IP="45.135.234.22"
DEPLOY_USER="deploy"

echo "🌐 Настройка Nginx для IKEA API и Frontend..."

# Функция для выполнения команд на сервере
ssh_exec() {
    ssh "$DEPLOY_USER@$SERVER_IP" "$@"
}

echo "📦 Установка Nginx на сервере..."
ssh_exec "sudo apt-get update && sudo apt-get install -y nginx"

echo "📝 Копирование конфигурации Nginx..."
scp config/nginx/ikea_api.conf "$DEPLOY_USER@$SERVER_IP:/tmp/ikea_api.conf"

echo "🔧 Настройка конфигурации Nginx..."
ssh_exec "sudo mv /tmp/ikea_api.conf /etc/nginx/sites-available/ikea_api && \
          sudo ln -sf /etc/nginx/sites-available/ikea_api /etc/nginx/sites-enabled/ikea_api && \
          sudo rm -f /etc/nginx/sites-enabled/default"

echo "📁 Создание директории для фронтенда..."
ssh_exec "sudo mkdir -p /var/www/ikea_frontend/dist && \
          sudo chown -R $DEPLOY_USER:$DEPLOY_USER /var/www/ikea_frontend"

echo "✅ Проверка конфигурации Nginx..."
ssh_exec "sudo nginx -t"

echo "🔄 Перезапуск Nginx..."
ssh_exec "sudo systemctl restart nginx && \
          sudo systemctl enable nginx"

echo "✅ Nginx настроен!"
echo ""
echo "📝 Следующие шаги:"
echo "1. Убедитесь, что Kamal приложение запущено:"
echo "   kamal app details"
echo ""
echo "2. Проверьте работу API:"
echo "   curl http://$SERVER_IP/api/v1/products"
echo "   curl http://$SERVER_IP/up"
echo ""
echo "3. Разместите собранный фронтенд в:"
echo "   /var/www/ikea_frontend/dist"
echo ""
echo "4. После добавления домена:"
echo "   - Обновите server_name в /etc/nginx/sites-available/ikea_api"
echo "   - Настройте SSL через certbot:"
echo "     sudo certbot --nginx -d your-domain.com"


