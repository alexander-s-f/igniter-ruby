# frozen_string_literal: true

require "rspec"

AI_SPEC_ROOT = File.expand_path("../../..", __dir__) unless defined?(AI_SPEC_ROOT)
$LOAD_PATH.unshift(File.expand_path("packages/igniter-ai/lib", AI_SPEC_ROOT))

require "igniter-ai"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
