# Production server configuration
server "185.47.153.112", user: "deploy", roles: %w{app db web}

# На prod Ruby через rbenv (на staging — asdf)
set :ruby_version_manager, :rbenv
set :ruby_env_prefix, 'export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"'
set :default_env, {
  'PATH' => "$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
}

# SSH опции - используем только publickey (SSH ключи уже настроены)
set :ssh_options, {
  keys: %w(~/.ssh/id_ed25519 ~/.ssh/id_rsa),
  port: 2200,
  forward_agent: false,
  auth_methods: %w(publickey),
  verify_host_key: :never
}
