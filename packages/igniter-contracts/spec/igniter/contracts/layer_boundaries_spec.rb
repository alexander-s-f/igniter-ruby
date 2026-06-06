# frozen_string_literal: true

require_relative "../../spec_helper"

RSpec.describe "Igniter::Contracts assembly/execution boundaries" do
  CONTRACTS_ROOT = File.expand_path("../../../lib/igniter/contracts", __dir__)

  ASSEMBLY_ALLOWED_EXECUTION_REFERENCES = {
    "assembly/baseline_pack.rb" => %w[
      Execution::BaselineNormalizers
      Execution::BaselineRuntime
      Execution::BaselineValidators
      Execution::ConstRuntime
      Execution::InlineExecutor
    ],
    "assembly/const_pack.rb" => %w[
      Execution::ConstRuntime
    ],
    "assembly/step_result_pack.rb" => %w[
      Execution::StepResultDiagnostics
      Execution::StepResultRuntime
      Execution::StepResultValidators
    ],
    "assembly/hook_result_policies.rb" => %w[
      Execution::ExecutionResult
      Execution::Operation
      Execution::ValidationFinding
    ]
  }.freeze

  EXECUTION_ALLOWED_ASSEMBLY_REFERENCES = {
    "execution/compiler.rb" => %w[
      Assembly::HookSpecs
    ]
  }.freeze

  def read_contract_file(relative_path)
    File.read(File.join(CONTRACTS_ROOT, relative_path))
  end

  def namespace_references(relative_path, namespace)
    read_contract_file(relative_path)
      .scan(/\b#{Regexp.escape(namespace)}::[A-Za-z0-9_:]+/)
      .uniq
      .sort
  end

  it "keeps core Assembly infrastructure free from Execution implementation references" do
    assembly_files = Dir.glob(File.join(CONTRACTS_ROOT, "assembly/*.rb"))
                        .map { |path| path.delete_prefix("#{CONTRACTS_ROOT}/") }
                        .sort

    core_files = assembly_files.reject { |relative_path| ASSEMBLY_ALLOWED_EXECUTION_REFERENCES.key?(relative_path) }

    core_files.each do |relative_path|
      expect(namespace_references(relative_path, "Execution")).to eq([]), relative_path
    end
  end

  it "limits Assembly -> Execution references to explicit registration and contract files" do
    ASSEMBLY_ALLOWED_EXECUTION_REFERENCES.each do |relative_path, allowed_references|
      expect(namespace_references(relative_path, "Execution")).to eq(allowed_references.sort), relative_path
    end
  end

  it "keeps Execution free from Assembly mutation internals" do
    execution_files = Dir.glob(File.join(CONTRACTS_ROOT, "execution/*.rb"))
                         .map { |path| path.delete_prefix("#{CONTRACTS_ROOT}/") }
                         .sort

    execution_files.each do |relative_path|
      allowed_references = EXECUTION_ALLOWED_ASSEMBLY_REFERENCES.fetch(relative_path, [])
      expect(namespace_references(relative_path, "Assembly")).to eq(allowed_references.sort), relative_path
    end
  end

  it "does not reference legacy Core namespaces from the new contracts implementation" do
    contract_files = Dir.glob(File.join(CONTRACTS_ROOT, "**/*.rb"))
                        .map { |path| path.delete_prefix("#{CONTRACTS_ROOT}/") }
                        .sort

    contract_files.each do |relative_path|
      expect(namespace_references(relative_path, "Core")).to eq([]), relative_path
    end
  end

  it "does not require igniter-core from contracts implementation files" do
    contract_files = Dir.glob(File.join(CONTRACTS_ROOT, "**/*.rb")).sort

    offenders = contract_files.each_with_object({}) do |path, memo|
      lines = File.readlines(path, chomp: true).filter_map do |line|
        stripped = line.strip
        next unless stripped.start_with?("require ", "require_relative ")
        next unless stripped.match?(%r{igniter/core|igniter-core})

        stripped
      end

      memo[path.delete_prefix("#{CONTRACTS_ROOT}/")] = lines unless lines.empty?
    end

    expect(offenders).to eq({})
  end
end
