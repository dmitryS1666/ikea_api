namespace :deploy do
  desc 'Принудительная перекомпиляция assets с очисткой кеша'
  task :force_assets_recompile do
    on roles(:app) do
      within release_path do
        with rails_env: fetch(:rails_env) do
          execute :rake, 'assets:clobber'
          execute :rake, 'assets:precompile'
        end
      end
    end
  end
end

# Хук после деплоя для принудительной перекомпиляции
after 'deploy:updated', 'deploy:force_assets_recompile'
