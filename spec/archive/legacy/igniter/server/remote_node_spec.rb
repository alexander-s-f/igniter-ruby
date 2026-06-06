# frozen_string_literal: true

require "spec_helper"
require "igniter/server"

RSpec.describe "remote: DSL node" do
  let(:store) { Igniter::Runtime::Stores::MemoryStore.new }

  around do |example|
    previous_adapter = Igniter::Runtime.remote_adapter
    Igniter::Server.activate_remote_adapter!
    example.run
    Igniter::Runtime.remote_adapter = previous_adapter
  end

  describe "compilation" do
    it "compiles a graph with a remote: node" do
      expect do
        Class.new(Igniter::Contract) do
          define do
            input :data
            remote :result,
                   contract: "OtherContract",
                   node: "http://localhost:4568",
                   inputs: { raw: :data }
            output :result
          end
        end
      end.not_to raise_error
    end

    it "raises CompileError when inputs: is not a Hash" do
      expect do
        Class.new(Igniter::Contract) do
          define do
            input :data
            remote :result,
                   contract: "OtherContract",
                   node: "http://localhost:4568",
                   inputs: :wrong
          end
        end
      end.to raise_error(Igniter::CompileError, /inputs: Hash/)
    end

    it "raises ValidationError for an invalid URL" do
      expect do
        Class.new(Igniter::Contract) do
          define do
            input :data
            remote :result,
                   contract: "OtherContract",
                   node: "ftp://localhost:4568",
                   inputs: { raw: :data }
            output :result
          end
        end
      end.to raise_error(Igniter::ValidationError, /invalid node: URL/)
    end

    it "raises ValidationError when dependency is not in graph" do
      expect do
        Class.new(Igniter::Contract) do
          define do
            input :data
            remote :result,
                   contract: "OtherContract",
                   node: "http://localhost:4568",
                   inputs: { raw: :nonexistent }
            output :result
          end
        end
      end.to raise_error(Igniter::ValidationError, /nonexistent/)
    end
  end

  describe "runtime resolution" do
    let(:contract_class) do
      Class.new(Igniter::Contract) do
        define do
          input :data
          remote :result,
                 contract: "OtherContract",
                 node: "http://localhost:4568",
                 inputs: { raw: :data }
          output :result
        end
      end
    end

    context "when the remote node responds with success" do
      before do
        # Stub Client#execute to return success
        allow_any_instance_of(Igniter::Server::Client).to receive(:execute)
          .with("OtherContract", inputs: { raw: "hello" })
          .and_return({ status: :succeeded, outputs: { processed: "HELLO" } })
      end

      it "resolves the remote node and returns outputs" do
        contract = contract_class.new({ data: "hello" })
        contract.resolve_all
        expect(contract.success?).to be true
        expect(contract.result.result).to eq({ processed: "HELLO" })
      end
    end

    context "when the remote node is unreachable" do
      before do
        allow_any_instance_of(Igniter::Server::Client).to receive(:execute)
          .and_raise(Igniter::Server::Client::ConnectionError, "connection refused")
      end

      it "raises ResolutionError with connection context" do
        contract = contract_class.new({ data: "hello" })
        expect { contract.resolve_all }
          .to raise_error(Igniter::ResolutionError, /Cannot reach/)
      end
    end

    context "when the remote contract fails" do
      before do
        allow_any_instance_of(Igniter::Server::Client).to receive(:execute)
          .and_return({ status: :failed, error: { "message" => "division by zero" } })
      end

      it "raises ResolutionError with the remote error message" do
        contract = contract_class.new({ data: "hello" })
        expect { contract.resolve_all }
          .to raise_error(Igniter::ResolutionError, /division by zero/)
      end
    end
  end
end
