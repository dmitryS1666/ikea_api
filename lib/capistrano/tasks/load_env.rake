# Задача для загрузки переменных окружения из .env файла
# Модифицирует команды так, чтобы они загружали переменные из .env перед выполнением
namespace :deploy do
  desc "Настроить загрузку переменных окружения из .env"
  task :setup_env_loader do
    # Используем deploy_to для получения пути к shared/.env
    deploy_to = fetch(:deploy_to)
    env_file = "#{deploy_to}/shared/.env"
    
    # Модифицируем команды через command_map с префиксом
    # Это будет применяться ко всем командам, включая rake, bundle, rails
    SSHKit.config.command_map.prefix[:rake].unshift(
      "source #{env_file} 2>/dev/null || true &&"
    )
    SSHKit.config.command_map.prefix[:bundle].unshift(
      "source #{env_file} 2>/dev/null || true &&"
    )
    SSHKit.config.command_map.prefix[:rails].unshift(
      "source #{env_file} 2>/dev/null || true &&"
    )
    
    info "✅ Настроена загрузка переменных из #{env_file}"
  end
end

# Настраивать загрузку .env перед выполнением задач деплоя
before "deploy:starting", "deploy:setup_env_loader"

