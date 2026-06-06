# frozen_string_literal: true

require_relative "../../lib/igniter/version"

Gem::Specification.new do |spec|
  spec.name = "igniter-ledger"
  spec.version = Igniter::VERSION
  spec.authors = ["Alexander"]
  spec.email = ["alexander.s.fokin@gmail.com"]

  spec.summary = "Contract-native Ledger substrate for Igniter"
  spec.description = "Pre-v1 Ledger package for Igniter: immutable facts, histories, receipts, replay, changefeed, compaction, and protocol-facing storage surfaces."
  spec.homepage = "https://github.com/alexander-s-f/igniter-ruby"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.files = Dir[
    "lib/**/*.rb",
    "ext/**/*.{rb,rs,toml}",
    "examples/**/*.rb",
    "exe/*",
    "README.md"
  ].sort

  spec.bindir      = "exe"
  spec.executables = ["igniter-ledger-server", "igniter-store-server"]

  spec.require_paths = ["lib"]
  spec.extensions    = ["ext/igniter_store_native/extconf.rb"]

  spec.add_dependency "rack",    "~> 3.0"
  spec.add_dependency "msgpack", "~> 1.0"

  spec.add_development_dependency "rb_sys", "~> 0.9"
  spec.add_development_dependency "rake-compiler", "~> 1.2"
  spec.add_development_dependency "rspec", "~> 3.0"
  spec.add_development_dependency "rake", "~> 13.0"
  spec.add_development_dependency "puma", "~> 6.0"
  spec.add_development_dependency "rack-test", "~> 2.0"
end
