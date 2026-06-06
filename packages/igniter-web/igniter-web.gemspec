# frozen_string_literal: true

require_relative "../../lib/igniter/version"

Gem::Specification.new do |spec|
  spec.name = "igniter-web"
  spec.version = Igniter::VERSION
  spec.authors = ["Alexander"]
  spec.email = ["alexander.s.fokin@gmail.com"]

  spec.summary = "Contracts-first web runtime and authoring lane for Igniter"
  spec.description = [
    "Web package for Igniter that combines a contracts-first API surface,",
    "a higher-level application authoring DSL, and an optional adapter-backed",
    "record facade for persistence-facing workflows."
  ].join(" ")
  spec.homepage = "https://github.com/alexander-s-f/igniter-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.files = Dir[
    "lib/**/*.rb",
    "README.md"
  ].sort

  spec.require_paths = ["lib"]

  spec.add_dependency "arbre"
  spec.add_dependency "igniter-application", Igniter::VERSION
end
