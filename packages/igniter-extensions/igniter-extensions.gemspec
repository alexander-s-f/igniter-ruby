# frozen_string_literal: true

require_relative "../../lib/igniter/version"

Gem::Specification.new do |spec|
  spec.name = "igniter-extensions"
  spec.version = Igniter::VERSION
  spec.authors = ["Alexander"]
  spec.email = ["alexander.s.fokin@gmail.com"]

  spec.summary = "Contracts-native extension packs for Igniter"
  spec.description = "Public contracts-native extension packs for Igniter built on top of igniter-contracts."
  spec.homepage = "https://github.com/alexander-s-f/igniter-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.files = Dir[
    "lib/**/*.rb",
    "README.md"
  ].sort

  spec.require_paths = ["lib"]

  spec.add_dependency "igniter-contracts", Igniter::VERSION
end
