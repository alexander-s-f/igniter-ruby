# frozen_string_literal: true

require "rspec"

HUB_SPEC_ROOT = File.expand_path("../../..", __dir__) unless defined?(HUB_SPEC_ROOT)
$LOAD_PATH.unshift(File.expand_path("packages/igniter-hub/lib", HUB_SPEC_ROOT))

require "igniter-hub"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
end
