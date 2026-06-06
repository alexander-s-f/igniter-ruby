Gem::Specification.new do |spec|
  spec.name          = "igniter-durable-model"
  spec.version       = "0.1.0"
  spec.summary       = "Durable Model Record/History layer backed by igniter-ledger"
  spec.description   = "Typed Durable Model Record, History, Store, scope, receipt, and manifest facade over igniter-ledger."
  spec.authors       = ["Alexander"]
  spec.require_paths = ["lib"]
  spec.files         = Dir["lib/**/*.rb"]

  spec.add_dependency "igniter-ledger"
  spec.add_dependency "igniter-ledger-client"
end
