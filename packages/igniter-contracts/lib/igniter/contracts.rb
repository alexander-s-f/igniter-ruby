# frozen_string_literal: true

require_relative "contracts/errors"
require_relative "contracts/environment"
require_relative "contracts/assembly"
require_relative "contracts/execution"
require_relative "contracts/contractable"
require_relative "contracts/contract"

module Igniter
  module Contracts
    Registry = Assembly::Registry
    OrderedRegistry = Assembly::OrderedRegistry
    Pack = Assembly::Pack
    PackManifest = Assembly::PackManifest
    NodeType = Assembly::NodeType
    DslKeyword = Assembly::DslKeyword
    HookResultPolicies = Assembly::HookResultPolicies
    HookSpec = Assembly::HookSpec
    HookSpecs = Assembly::HookSpecs
    Profile = Assembly::Profile
    Kernel = Assembly::Kernel
    PathAccess = Assembly::PathAccess
    BaselinePack = Assembly::BaselinePack
    ConstPack = Assembly::ConstPack
    ProjectPack = Assembly::ProjectPack
    StepResultPack = Assembly::StepResultPack

    CompiledGraph = Execution::CompiledGraph
    Builder = Execution::Builder
    Compiler = Execution::Compiler
    ExecutionResult = Execution::ExecutionResult
    Runtime = Execution::Runtime
    DiagnosticsReport = Execution::DiagnosticsReport
    Diagnostics = Execution::Diagnostics
    BaselineNormalizers = Execution::BaselineNormalizers
    BaselineValidators = Execution::BaselineValidators
    BaselineRuntime = Execution::BaselineRuntime
    ConstRuntime = Execution::ConstRuntime
    InlineExecutor = Execution::InlineExecutor
    Operation = Execution::Operation
    NamedValues = Execution::NamedValues
    EffectInvocation = Execution::EffectInvocation
    ExecutionRequest = Execution::ExecutionRequest
    DiagnosticsSection = Execution::DiagnosticsSection
    ValidationFinding = Execution::ValidationFinding
    ValidationReport = Execution::ValidationReport
    CompilationReport = Execution::CompilationReport
    MutableNamedValues = Execution::MutableNamedValues
    StepResult = Execution::StepResult
  end
end

require_relative "contracts/api"
