# Production server configuration
server "185.47.153.112", user: "deploy", roles: %w{app db web}

# На prod Ruby через rbenv (на staging — asdf)
set :ruby_version_manager, :rbenv
set :ruby_env_prefix, 'export PATH="$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"'
set :default_env, {
  'PATH' => "$HOME/.rbenv/bin:$HOME/.rbenv/shims:$PATH"
}

# SSH: на prod в authorized_keys лежит ikea_front_prod_github_actions (не id_rsa/id_ed25519).
# keys_only + use_agent: false — один ключ с диска, без перебора ssh-agent (Too many authentication failures).
set :ssh_options, {
  keys: [File.expand_path("~/.ssh/ikea_front_prod_github_actions")],
  keys_only: true,
  use_agent: false,
  port: 2200,
  forward_agent: false,
  auth_methods: %w(publickey),
  verify_host_key: :never
}
