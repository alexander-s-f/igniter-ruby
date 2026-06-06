# frozen_string_literal: true

require_relative "../../lib/igniter/version"

Gem::Specification.new do |spec|
  spec.name = "igniter-contracts"
  spec.version = Igniter::VERSION
  spec.authors = ["Alexander"]
  spec.email = ["alexander.s.fokin@gmail.com"]

  spec.summary = "Embedded contracts kernel for Igniter"
  spec.description = "Public embedded package for Igniter contracts, graph compilation, execution, diagnostics, and core runtime seams."
  spec.homepage = "https://github.com/alexander-s-f/igniter-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.files = Dir[
    "lib/**/*.rb",
    "README.md"
  ].sort

  spec.require_paths = ["lib"]
end
