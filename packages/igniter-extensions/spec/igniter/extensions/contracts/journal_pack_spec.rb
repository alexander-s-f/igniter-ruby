# frozen_string_literal: true

require_relative "../../../spec_helper"

RSpec.describe Igniter::Extensions::Contracts::JournalPack do
  before do
    described_class.reset_journal!
  end

  it "applies an external effect through the public contracts effect seam" do
    environment = Igniter::Contracts.with(described_class)

    result = environment.apply_effect(
      :journal,
      payload: { amount: 10 },
      context: { source: :spec }
    )

    expect(result).to eq(amount: 10)
    expect(described_class.journal[:effects]).to eq([{
                                                      payload: { amount: 10 },
                                                      context: { source: :spec },
                                                      profile_fingerprint: environment.profile.fingerprint
                                                    }])
  end

  it "works as a graph-native baseline effect adapter" do
    environment = Igniter::Contracts.with(described_class)

    result = environment.run(inputs: { amount: 10 }) do
      input :amount
      effect :journal_entry, using: :journal, depends_on: [:amount] do |amount:|
        { amount: amount, source: :graph }
      end
      output :journal_entry
    end

    expect(result.output(:journal_entry)).to eq(amount: 10, source: :graph)
    expect(described_class.journal[:effects]).to eq([{
                                                      payload: { amount: 10, source: :graph },
                                                      context: {
                                                        node_name: :journal_entry,
                                                        effect_name: :journal,
                                                        dependencies: { amount: 10 }
                                                      },
                                                      profile_fingerprint: environment.profile.fingerprint
                                                    }])
  end

  it "executes through an external executor and records request and result" do
    environment = Igniter::Contracts.with(described_class)

    compiled = environment.compile do
      input :amount
      output :amount
    end

    result = environment.execute_with(:journaled_inline, compiled, inputs: { amount: 15 })

    expect(result.output(:amount)).to eq(15)
    expect(described_class.journal[:executions]).to eq([{
                                                         compiled_graph: {
                                                           operations: [
                                                             { kind: :input, name: :amount, attributes: {} },
                                                             { kind: :output, name: :amount, attributes: {} }
                                                           ],
                                                           profile_fingerprint: environment.profile.fingerprint
                                                         },
                                                         inputs: { amount: 15 },
                                                         profile_fingerprint: environment.profile.fingerprint,
                                                         runtime: "Igniter::Contracts::Execution::Runtime"
                                                       }])
    expect(described_class.journal[:results]).to eq([{
                                                      state: { amount: 15 },
                                                      outputs: { amount: 15 },
                                                      profile_fingerprint: environment.profile.fingerprint,
                                                      compiled_graph: {
                                                        operations: [
                                                          { kind: :input, name: :amount, attributes: {} },
                                                          { kind: :output, name: :amount, attributes: {} }
                                                        ],
                                                        profile_fingerprint: environment.profile.fingerprint
                                                      }
                                                    }])
  end
end
