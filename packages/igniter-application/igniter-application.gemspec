# frozen_string_literal: true

require_relative "../../lib/igniter/version"

Gem::Specification.new do |spec|
  spec.name = "igniter-application"
  spec.version = Igniter::VERSION
  spec.authors = ["Alexander"]
  spec.email = ["alexander.s.fokin@gmail.com"]

  spec.summary = "Contracts-native local application runtime for Igniter"
  spec.description = "Clean-slate local application runtime package for Igniter built directly on igniter-contracts without inheriting the legacy igniter-app surface."
  spec.homepage = "https://github.com/alexander-s-f/igniter-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.files = Dir[
    "lib/**/*.rb",
    "README.md"
  ].sort

  spec.require_paths = ["lib"]

  spec.add_dependency "igniter-contracts", Igniter::VERSION
  spec.add_dependency "igniter-extensions", Igniter::VERSION
  spec.add_dependency "igniter-ai", Igniter::VERSION
  spec.add_dependency "igniter-agents", Igniter::VERSION
end
