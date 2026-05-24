#!/bin/bash
# Скрипт для настройки SSH ключа для GitHub на сервере

set -e

SSH_PORT="${SSH_PORT:-22}"
SERVER="${SERVER:-deploy@45.135.234.22}"
SSH_OPTS=()
if [ "$SSH_PORT" != "22" ]; then
  SSH_OPTS=(-p "$SSH_PORT")
fi

echo "🔑 Настройка SSH ключа для GitHub..."

# Проверка существующих ключей
echo "🔍 Проверка существующих SSH ключей..."
ssh "${SSH_OPTS[@]}" "$SERVER" << 'EOF'
# Проверить существующие ключи
if [ -f ~/.ssh/id_ed25519.pub ]; then
    echo "✅ Найден ключ id_ed25519"
    cat ~/.ssh/id_ed25519.pub
elif [ -f ~/.ssh/id_rsa.pub ]; then
    echo "✅ Найден ключ id_rsa"
    cat ~/.ssh/id_rsa.pub
else
    echo "📦 Создание нового SSH ключа..."
    ssh-keygen -t ed25519 -C "deploy@ikea_api" -f ~/.ssh/id_ed25519 -N ""
    echo "✅ SSH ключ создан"
    cat ~/.ssh/id_ed25519.pub
fi
EOF

echo ""
echo "📋 СЛЕДУЮЩИЕ ШАГИ:"
echo ""
echo "1. Скопируйте публичный ключ выше"
echo ""
echo "2. Добавьте ключ в GitHub:"
echo "   - Перейдите: https://github.com/settings/ssh/new"
echo "   - Вставьте публичный ключ"
echo "   - Нажмите 'Add SSH key'"
echo ""
echo "3. Проверьте подключение:"
echo "   ssh ${SSH_OPTS[*]} $SERVER 'ssh -T git@github.com'"
echo ""
echo "4. Если нужно скопировать ключ вручную:"
echo "   ssh ${SSH_OPTS[*]} $SERVER 'cat ~/.ssh/id_ed25519.pub'"
echo ""

