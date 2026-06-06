# frozen_string_literal: true

require "rspec"

AGENTS_SPEC_ROOT = File.expand_path("../../..", __dir__) unless defined?(AGENTS_SPEC_ROOT)
$LOAD_PATH.unshift(File.expand_path("packages/igniter-agents/lib", AGENTS_SPEC_ROOT))
$LOAD_PATH.unshift(File.expand_path("packages/igniter-ai/lib", AGENTS_SPEC_ROOT))

require "igniter-agents"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
