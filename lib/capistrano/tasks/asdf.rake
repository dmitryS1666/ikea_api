# Проверка Ruby (asdf на staging, rbenv на production)
namespace :asdf do
  desc "Проверка установки Ruby"
  task :check do
    on roles(:app) do
      case fetch(:ruby_version_manager, :asdf)
      when :rbenv
        execute %(bash -lc 'ruby -v')
      else
        execute "source $HOME/.asdf/asdf.sh && asdf current ruby"
      end
    end
  end

  desc "Установить Ruby версию для проекта (только asdf)"
  task :set_ruby_version do
    on roles(:app) do
      next unless fetch(:ruby_version_manager, :asdf) == :asdf

      within release_path do
        execute "source $HOME/.asdf/asdf.sh && asdf local ruby #{fetch(:asdf_ruby_version)}"
      end
    end
  end
end

before "deploy:starting", "asdf:check"
