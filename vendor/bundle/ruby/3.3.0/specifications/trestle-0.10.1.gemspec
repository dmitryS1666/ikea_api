# -*- encoding: utf-8 -*-
# stub: trestle 0.10.1 ruby lib

Gem::Specification.new do |s|
  s.name = "trestle".freeze
  s.version = "0.10.1".freeze

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.require_paths = ["lib".freeze]
  s.authors = ["Sam Pohlenz".freeze]
  s.date = "2024-09-27"
  s.description = "Trestle is a modern, responsive admin framework for Ruby on Rails.".freeze
  s.email = ["sam@sampohlenz.com".freeze]
  s.homepage = "https://www.trestle.io".freeze
  s.licenses = ["LGPL-3.0-only".freeze]
  s.required_ruby_version = Gem::Requirement.new(">= 2.6.0".freeze)
  s.rubygems_version = "3.5.3".freeze
  s.summary = "A modern, responsive admin framework for Ruby on Rails".freeze

  s.installed_by_version = "3.5.3".freeze if s.respond_to? :installed_by_version

  s.specification_version = 4

  s.add_runtime_dependency(%q<railties>.freeze, [">= 6.0.0".freeze])
  s.add_runtime_dependency(%q<activemodel>.freeze, [">= 6.0.0".freeze])
  s.add_runtime_dependency(%q<turbo-rails>.freeze, [">= 2.0.6".freeze])
  s.add_runtime_dependency(%q<kaminari>.freeze, [">= 1.1.0".freeze])
  s.add_development_dependency(%q<rspec-rails>.freeze, [">= 5.1.2".freeze])
  s.add_development_dependency(%q<rspec-html-matchers>.freeze, ["~> 0.10.0".freeze])
  s.add_development_dependency(%q<database_cleaner>.freeze, ["~> 2.0.2".freeze])
  s.add_development_dependency(%q<ammeter>.freeze, ["~> 1.1.5".freeze])
end
