# frozen_string_literal: true

require "rspec"

CONTRACTS_SPEC_ROOT = File.expand_path("../../..", __dir__) unless defined?(CONTRACTS_SPEC_ROOT)
$LOAD_PATH.unshift(File.expand_path("packages/igniter-contracts/lib", CONTRACTS_SPEC_ROOT))
$LOAD_PATH.unshift(File.expand_path("packages/igniter-core/lib", CONTRACTS_SPEC_ROOT))

require "igniter/contracts"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }

  config.before do
    Igniter::Contracts.reset_defaults!
  end
end
