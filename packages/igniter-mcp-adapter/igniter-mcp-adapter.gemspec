# frozen_string_literal: true

require_relative "../../lib/igniter/version"

Gem::Specification.new do |spec|
  spec.name = "igniter-mcp-adapter"
  spec.version = Igniter::VERSION
  spec.authors = ["Alexander"]
  spec.email = ["alexander.s.fokin@gmail.com"]

  spec.summary = "Thin MCP adapter package over Igniter tooling surfaces"
  spec.description = "Transport-facing MCP adapter package for Igniter that exposes the stabilized tooling catalog and invocation surface built in igniter-extensions."
  spec.homepage = "https://github.com/alexander-s-f/igniter-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.files = Dir[
    "lib/**/*.rb",
    "exe/*",
    "README.md"
  ].sort

  spec.require_paths = ["lib"]
  spec.bindir = "exe"
  spec.executables = ["igniter-mcp-adapter"]

  spec.add_dependency "igniter-extensions", Igniter::VERSION
end
