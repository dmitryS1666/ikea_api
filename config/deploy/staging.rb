# Staging server configuration (бывший production)
# На сервере БД, .env и Sidekiq настроены под production — не меняем RAILS_ENV.
set :rails_env, :production

server "45.135.234.22", user: "deploy", roles: %w{app db web}

# SSH опции - используем только publickey (SSH ключи уже настроены)
set :ssh_options, {
  keys: %w(~/.ssh/id_ed25519 ~/.ssh/id_rsa),
  forward_agent: false,
  auth_methods: %w(publickey),
  verify_host_key: :never
}
