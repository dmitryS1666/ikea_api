# -*- encoding: utf-8 -*-
# stub: google-gax 1.8.2 ruby lib

Gem::Specification.new do |s|
  s.name = "google-gax".freeze
  s.version = "1.8.2".freeze

  s.required_rubygems_version = Gem::Requirement.new(">= 0".freeze) if s.respond_to? :required_rubygems_version=
  s.require_paths = ["lib".freeze]
  s.authors = ["Google API Authors".freeze]
  s.date = "2021-09-13"
  s.description = "Google API Extensions".freeze
  s.email = "googleapis-packages@google.com".freeze
  s.homepage = "https://github.com/googleapis/gax-ruby".freeze
  s.licenses = ["BSD-3-Clause".freeze]
  s.post_install_message = "*******************************************************************************\nThe google-gax gem is officially end-of-life and will not be updated further.\n\nIf your app uses the google-gax gem, it likely is using obsolete versions of\nsome Google Cloud client library (google-cloud-*) gem that depends on it. We\nrecommend updating any such libraries that depend on google-gax. Modern Google\nCloud client libraries will depend on the gapic-common gem instead.\n*******************************************************************************\n".freeze
  s.required_ruby_version = Gem::Requirement.new(">= 2.4.0".freeze)
  s.rubygems_version = "3.5.3".freeze
  s.summary = "Aids the development of APIs for clients and servers based on GRPC and Google APIs conventions".freeze

  s.installed_by_version = "3.5.3".freeze if s.respond_to? :installed_by_version

  s.specification_version = 4

  s.add_runtime_dependency(%q<googleauth>.freeze, ["~> 0.9".freeze])
  s.add_runtime_dependency(%q<grpc>.freeze, ["~> 1.24".freeze])
  s.add_runtime_dependency(%q<googleapis-common-protos>.freeze, [">= 1.3.9".freeze, "< 2.0".freeze])
  s.add_runtime_dependency(%q<googleapis-common-protos-types>.freeze, [">= 1.0.4".freeze, "< 2.0".freeze])
  s.add_runtime_dependency(%q<google-protobuf>.freeze, ["~> 3.9".freeze])
  s.add_runtime_dependency(%q<rly>.freeze, ["~> 0.2.3".freeze])
  s.add_development_dependency(%q<codecov>.freeze, ["~> 0.1".freeze])
  s.add_development_dependency(%q<rake>.freeze, [">= 10.0".freeze])
  s.add_development_dependency(%q<rspec>.freeze, ["~> 3.0".freeze])
  s.add_development_dependency(%q<rubocop>.freeze, ["= 0.49.0".freeze])
  s.add_development_dependency(%q<simplecov>.freeze, ["~> 0.9".freeze])
end
