# frozen_string_literal: true

require "rspec"

LEDGER_CLIENT_SPEC_ROOT = File.expand_path("../../..", __dir__) unless defined?(LEDGER_CLIENT_SPEC_ROOT)
$LOAD_PATH.unshift(File.expand_path("packages/igniter-ledger-client/lib", LEDGER_CLIENT_SPEC_ROOT))

require "igniter-ledger-client"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
