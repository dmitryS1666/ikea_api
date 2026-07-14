# -*- encoding: utf-8 -*-
# stub: trestle-tinymce 0.4.0 ruby lib

Gem::Specification.new do |s|
  s.name = "trestle-tinymce".freeze
  s.version = "0.4.0".freeze

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.require_paths = ["lib".freeze]
  s.authors = ["Sam Pohlenz".freeze]
  s.date = "2024-08-16"
  s.description = "TinyMCE integration plugin for the Trestle admin framework.".freeze
  s.email = ["sam@sampohlenz.com".freeze]
  s.homepage = "https://www.trestle.io".freeze
  s.licenses = ["LGPL-3.0-only".freeze]
  s.rubygems_version = "3.5.3".freeze
  s.summary = "TinyMCE integration plugin for the Trestle admin framework".freeze

  s.installed_by_version = "3.5.3".freeze if s.respond_to? :installed_by_version

  s.specification_version = 4

  s.add_runtime_dependency(%q<trestle>.freeze, ["~> 0.10.0".freeze])
  s.add_runtime_dependency(%q<tinymce-rails>.freeze, [">= 5.1".freeze, "< 7".freeze])
  s.add_development_dependency(%q<rspec-rails>.freeze, [">= 0".freeze])
end
