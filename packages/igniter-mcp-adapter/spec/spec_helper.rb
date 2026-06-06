# frozen_string_literal: true

require "rspec"

MCP_ADAPTER_SPEC_ROOT = File.expand_path("../../..", __dir__) unless defined?(MCP_ADAPTER_SPEC_ROOT)
$LOAD_PATH.unshift(File.expand_path("packages/igniter-mcp-adapter/lib", MCP_ADAPTER_SPEC_ROOT))
$LOAD_PATH.unshift(File.expand_path("packages/igniter-extensions/lib", MCP_ADAPTER_SPEC_ROOT))
$LOAD_PATH.unshift(File.expand_path("packages/igniter-contracts/lib", MCP_ADAPTER_SPEC_ROOT))
$LOAD_PATH.unshift(File.expand_path("packages/igniter-core/lib", MCP_ADAPTER_SPEC_ROOT))

require "igniter-mcp-adapter"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }

  config.before do
    Igniter::Contracts.reset_defaults!
  end
end
