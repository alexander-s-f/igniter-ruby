# frozen_string_literal: true

ENV["IGNITER_LEGACY_CORE_REQUIRE"] ||= "off"

require "igniter"

RSpec.configure do |config|
  config.disable_monkey_patching!
  config.expect_with(:rspec) { |c| c.syntax = :expect }

  config.around do |example|
    runtime_context_defined = defined?(Igniter::App::RuntimeContext)
    previous_context = Igniter::App::RuntimeContext.current if runtime_context_defined
    previous_sdk_activations = defined?(Igniter::SDK) ? Igniter::SDK.activated_capabilities.dup : nil
    Igniter::App::RuntimeContext.current = nil if runtime_context_defined
    example.run
  ensure
    if defined?(Igniter::App::RuntimeContext)
      Igniter::App::RuntimeContext.current = runtime_context_defined ? previous_context : nil
    end
    Igniter::SDK.instance_variable_set(:@activated_capabilities, previous_sdk_activations) if defined?(Igniter::SDK)
  end
end
