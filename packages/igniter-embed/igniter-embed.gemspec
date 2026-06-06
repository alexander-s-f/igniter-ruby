# frozen_string_literal: true

require_relative "../../lib/igniter/version"

Gem::Specification.new do |spec|
  spec.name = "igniter-embed"
  spec.version = Igniter::VERSION
  spec.authors = ["Alexander"]
  spec.email = ["alexander.s.fokin@gmail.com"]

  spec.summary = "Host-local embedded contract containers for Igniter"
  spec.description = "Embedded host container, registry, cache, and execution envelope for Igniter contracts."
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
end
