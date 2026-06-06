# frozen_string_literal: true

# Adds both gem lib/ dirs to load path so the playground runs from any cwd.
$LOAD_PATH.unshift(File.expand_path("../../lib", __dir__))
$LOAD_PATH.unshift(File.expand_path("../../../igniter-ledger/lib", __dir__))

require "igniter/durable_model"

# Require all playground tools and schemas.
Dir[File.join(__dir__, "schema",  "*.rb")].sort.each { |f| require f }
Dir[File.join(__dir__, "tools",   "*.rb")].sort.each { |f| require f }

module Playground
  # Unwrap a Logger wrapper (if present) and return the raw IgniterStore.
  # Demos that need direct access to internal state (coercion, checkpoint) use this.
  def self.inner_store(store_or_logger)
    durable_model = store_or_logger.respond_to?(:call_log) ?
      store_or_logger.instance_variable_get(:@store) :
      store_or_logger
    durable_model.instance_variable_get(:@inner)
  end

  # Convenience: build a fresh in-memory store with all schemas registered.
  def self.store
    s = Igniter::DurableModel::Store.new
    s.register(Schema::Task)
    s.register(Schema::TrackerEntry)
    s
  end

  # Build a file-backed store at +path+ with all schemas registered.
  def self.file_store(path)
    s = Igniter::DurableModel::Store.new(backend: :file, path: path)
    s.register(Schema::Task)
    s.register(Schema::TrackerEntry)
    s
  end
end
