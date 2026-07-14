# -*- encoding: utf-8 -*-
# stub: trestle-auth 0.5.0 ruby lib

Gem::Specification.new do |s|
  s.name = "trestle-auth".freeze
  s.version = "0.5.0".freeze

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.metadata = { "homepage_uri" => "https://www.trestle.io", "source_code_uri" => "https://github.com/TrestleAdmin/trestle-auth" } if s.respond_to? :metadata=
  s.require_paths = ["lib".freeze]
  s.authors = ["Sam Pohlenz".freeze]
  s.date = "2024-08-16"
  s.email = ["sam@sampohlenz.com".freeze]
  s.homepage = "https://www.trestle.io".freeze
  s.licenses = ["LGPL-3.0-only".freeze]
  s.required_ruby_version = Gem::Requirement.new(">= 2.6.0".freeze)
  s.rubygems_version = "3.5.3".freeze
  s.summary = "Authentication plugin for the Trestle admin framework".freeze

  s.installed_by_version = "3.5.3".freeze if s.respond_to? :installed_by_version

  s.specification_version = 4

  s.add_runtime_dependency(%q<trestle>.freeze, ["~> 0.10.0".freeze])
  s.add_runtime_dependency(%q<bcrypt>.freeze, ["~> 3.1.7".freeze])
  s.add_development_dependency(%q<rspec-rails>.freeze, [">= 0".freeze])
  s.add_development_dependency(%q<show_me_the_cookies>.freeze, ["~> 6.0".freeze])
  s.add_development_dependency(%q<timecop>.freeze, ["~> 0.9.1".freeze])
end
