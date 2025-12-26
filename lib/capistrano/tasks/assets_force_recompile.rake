namespace :deploy do
  desc 'Принудительная перекомпиляция assets с очисткой кеша'
  task :force_assets_recompile do
    on roles(:app) do
      within release_path do
        with rails_env: fetch(:rails_env) do
          # Удаляем старые assets
          execute :rake, 'assets:clobber'
          # Перекомпилируем assets
          execute :rake, 'assets:precompile'
          # Очищаем кеш Rails
          execute :rake, 'tmp:cache:clear'
        end
      end
    end
  end
end

# Хук после деплоя для принудительной перекомпиляции (перед стандартной компиляцией)
before 'deploy:assets:precompile', 'deploy:force_assets_recompile'
