# -*- encoding: utf-8 -*-
# stub: telegram-bot 0.16.7 ruby lib

Gem::Specification.new do |s|
  s.name = "telegram-bot".freeze
  s.version = "0.16.7".freeze

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.metadata = { "rubygems_mfa_required" => "true" } if s.respond_to? :metadata=
  s.require_paths = ["lib".freeze]
  s.authors = ["Max Melentiev".freeze]
  s.bindir = "exe".freeze
  s.date = "2025-01-15"
  s.email = ["melentievm@gmail.com".freeze]
  s.homepage = "https://github.com/telegram-bot-rb/telegram-bot".freeze
  s.licenses = ["MIT".freeze]
  s.required_ruby_version = Gem::Requirement.new(">= 2.4".freeze)
  s.rubygems_version = "3.5.3".freeze
  s.summary = "Library for building Telegram Bots with Rails integration".freeze

  s.installed_by_version = "3.5.3".freeze if s.respond_to? :installed_by_version

  s.specification_version = 4

  s.add_runtime_dependency(%q<actionpack>.freeze, [">= 4.0".freeze, "< 8.1".freeze])
  s.add_runtime_dependency(%q<activesupport>.freeze, [">= 4.0".freeze, "< 8.1".freeze])
  s.add_runtime_dependency(%q<httpclient>.freeze, ["~> 2.7".freeze])
  s.add_development_dependency(%q<bundler>.freeze, ["> 1.16".freeze])
  s.add_development_dependency(%q<rake>.freeze, ["~> 13.0".freeze])
end
