# frozen_string_literal: true

require "rspec"

EMBED_SPEC_ROOT = File.expand_path("../../..", __dir__) unless defined?(EMBED_SPEC_ROOT)
$LOAD_PATH.unshift(File.expand_path("packages/igniter-embed/lib", EMBED_SPEC_ROOT))
$LOAD_PATH.unshift(File.expand_path("packages/igniter-extensions/lib", EMBED_SPEC_ROOT))
$LOAD_PATH.unshift(File.expand_path("packages/igniter-contracts/lib", EMBED_SPEC_ROOT))

require "igniter/embed"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }

  config.before do
    Igniter::Contracts.reset_defaults!
  end
end
