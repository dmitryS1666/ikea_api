# -*- encoding: utf-8 -*-
# stub: google-cloud-translate 2.3.0 ruby lib

Gem::Specification.new do |s|
  s.name = "google-cloud-translate".freeze
  s.version = "2.3.0".freeze

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.require_paths = ["lib".freeze]
  s.authors = ["Google LLC".freeze]
  s.date = "2020-03-30"
  s.description = "google-cloud-translate is the official library for Cloud Translation API.".freeze
  s.email = "googleapis-packages@google.com".freeze
  s.homepage = "https://github.com/googleapis/google-cloud-ruby/tree/master/google-cloud-translate".freeze
  s.licenses = ["Apache-2.0".freeze]
  s.post_install_message = "The 2.0 release introduces breaking changes by defaulting to a\nnew generated v3 API client. This gem continues to contain the\nlegacy hand-written v2 client for backward compatibility aside\nfrom the default client constructor.\n\nFor more details please visit the 2.0.0 CHANGELOG:\nhttps://googleapis.dev/ruby/google-cloud-translate/v2.0.0/file.CHANGELOG.html#2_0_0___2019-10-28\n".freeze
  s.required_ruby_version = Gem::Requirement.new(">= 2.4".freeze)
  s.rubygems_version = "3.5.3".freeze
  s.summary = "API Client library for Cloud Translation API".freeze

  s.installed_by_version = "3.5.3".freeze if s.respond_to? :installed_by_version

  s.specification_version = 4

  s.add_runtime_dependency(%q<faraday>.freeze, [">= 0.17.3".freeze, "< 2.0".freeze])
  s.add_runtime_dependency(%q<google-cloud-core>.freeze, ["~> 1.2".freeze])
  s.add_runtime_dependency(%q<google-gax>.freeze, ["~> 1.8".freeze])
  s.add_runtime_dependency(%q<googleapis-common-protos>.freeze, [">= 1.3.9".freeze, "< 2.0".freeze])
  s.add_runtime_dependency(%q<googleapis-common-protos-types>.freeze, [">= 1.0.4".freeze, "< 2.0".freeze])
  s.add_development_dependency(%q<autotest-suffix>.freeze, ["~> 1.1".freeze])
  s.add_development_dependency(%q<google-style>.freeze, ["~> 1.24.0".freeze])
  s.add_development_dependency(%q<minitest>.freeze, ["~> 5.10".freeze])
  s.add_development_dependency(%q<minitest-autotest>.freeze, ["~> 1.0".freeze])
  s.add_development_dependency(%q<minitest-focus>.freeze, ["~> 1.1".freeze])
  s.add_development_dependency(%q<minitest-rg>.freeze, ["~> 5.2".freeze])
  s.add_development_dependency(%q<redcarpet>.freeze, ["~> 3.0".freeze])
  s.add_development_dependency(%q<simplecov>.freeze, ["~> 0.9".freeze])
  s.add_development_dependency(%q<yard>.freeze, ["~> 0.9".freeze])
  s.add_development_dependency(%q<yard-doctest>.freeze, ["~> 0.1.13".freeze])
end
