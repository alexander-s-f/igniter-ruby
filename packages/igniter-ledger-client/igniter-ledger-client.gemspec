# frozen_string_literal: true

require_relative "../../lib/igniter/version"

Gem::Specification.new do |spec|
  spec.name = "igniter-ledger-client"
  spec.version = Igniter::VERSION
  spec.authors = ["Alexander"]
  spec.email = ["alexander.s.fokin@gmail.com"]

  spec.summary = "Protocol-first Ledger client package for Igniter"
  spec.description = "Small client-side package for the Igniter Ledger/Open Protocol boundary: envelopes, transports, errors, and stable client methods without embedding the storage engine."
  spec.homepage = "https://github.com/alexander-s-f/igniter-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.files = Dir[
    "lib/**/*.rb",
    "README.md"
  ].sort

  spec.require_paths = ["lib"]
end
