# frozen_string_literal: true

require "spec_helper"

RSpec.describe "Igniter collections" do
  let(:technician_contract) do
    Class.new(Igniter::Contract) do
      define do
        input :technician_id
        input :name

        compute :summary, with: %i[technician_id name] do |technician_id:, name:|
          { id: technician_id, name: name }
        end

        output :summary
      end
    end
  end

  it "fans out over item input hashes and returns a collection result" do
    technician = technician_contract

    contract_class = Class.new(Igniter::Contract) do
      define do
        input :technician_inputs, type: :array

        collection :technicians, with: :technician_inputs, each: technician, key: :technician_id

        output :technicians
      end
    end

    contract = contract_class.new(technician_inputs: [
      { technician_id: 1, name: "Anna" },
      { technician_id: 2, name: "Mike" }
    ])

    result = contract.result.technicians

    expect(result).to be_a(Igniter::Runtime::CollectionResult)
    expect(result.keys).to eq([1, 2])
    expect(result[1].result.summary).to eq(id: 1, name: "Anna")
    expect(result[2].result.summary).to eq(id: 2, name: "Mike")
    expect(contract.result.to_h).to eq(
      technicians: {
        1 => { key: 1, status: :succeeded, result: { summary: { id: 1, name: "Anna" } } },
        2 => { key: 2, status: :succeeded, result: { summary: { id: 2, name: "Mike" } } }
      }
    )
  end

  it "collects per-item failures in collect mode" do
    failing_child = Class.new(Igniter::Contract) do
      define do
        input :technician_id
        input :name

        compute :summary, with: %i[technician_id name] do |technician_id:, name:|
          raise "boom" if technician_id == 2

          { id: technician_id, name: name }
        end

        output :summary
      end
    end

    contract_class = Class.new(Igniter::Contract) do
      define do
        input :technician_inputs, type: :array

        collection :technicians, with: :technician_inputs, each: failing_child, key: :technician_id, mode: :collect

        output :technicians
      end
    end

    contract = contract_class.new(technician_inputs: [
      { technician_id: 1, name: "Anna" },
      { technician_id: 2, name: "Mike" }
    ])

    result = contract.result.technicians

    expect(result.successes.keys).to eq([1])
    expect(result.failures.keys).to eq([2])
    expect(result[2].error.message).to match(/boom/)
    expect(result.items_summary[1]).to eq(status: :succeeded)
    expect(result.items_summary[2]).to include(status: :failed, error: include("boom"))
    expect(result.failed_items[2]).to include(type: "Igniter::ResolutionError", message: include("boom"))
  end

  it "fails fast in fail_fast mode" do
    failing_child = Class.new(Igniter::Contract) do
      define do
        input :technician_id

        compute :summary, with: :technician_id do |technician_id:|
          raise "boom" if technician_id == 2

          technician_id
        end

        output :summary
      end
    end

    contract_class = Class.new(Igniter::Contract) do
      define do
        input :technician_inputs, type: :array

        collection :technicians, with: :technician_inputs, each: failing_child, key: :technician_id, mode: :fail_fast

        output :technicians
      end
    end

    contract = contract_class.new(technician_inputs: [
      { technician_id: 1 },
      { technician_id: 2 }
    ])

    expect { contract.result.technicians }.to raise_error(Igniter::ResolutionError, /boom/)
  end

  it "fails at runtime for non-array inputs" do
    technician = technician_contract

    contract_class = Class.new(Igniter::Contract) do
      define do
        input :technician_inputs

        collection :technicians, with: :technician_inputs, each: technician, key: :technician_id

        output :technicians
      end
    end

    contract = contract_class.new(technician_inputs: { technician_id: 1, name: "Anna" })

    expect { contract.result.technicians }.to raise_error(Igniter::CollectionInputError, /expects an array/)
  end

  it "fails at runtime for duplicate keys" do
    technician = technician_contract

    contract_class = Class.new(Igniter::Contract) do
      define do
        input :technician_inputs, type: :array

        collection :technicians, with: :technician_inputs, each: technician, key: :technician_id

        output :technicians
      end
    end

    contract = contract_class.new(technician_inputs: [
      { technician_id: 1, name: "Anna" },
      { technician_id: 1, name: "Mike" }
    ])

    expect { contract.result.technicians }.to raise_error(Igniter::CollectionKeyError, /duplicate keys/)
  end

  it "renders collection metadata in graph introspection" do
    technician = technician_contract

    contract_class = Class.new(Igniter::Contract) do
      define do
        input :technician_inputs, type: :array

        collection :technicians, with: :technician_inputs, each: technician, key: :technician_id

        output :technicians
      end
    end

    text = contract_class.graph.to_text

    expect(text).to include("collection technicians")
    expect(text).to include("with=technician_inputs")
    expect(text).to include("key=technician_id")
    expect(text).to include("mode=collect")
  end

  it "emits item-level collection events" do
    failing_child = Class.new(Igniter::Contract) do
      define do
        input :technician_id

        compute :summary, with: :technician_id do |technician_id:|
          raise "boom" if technician_id == 2

          technician_id
        end

        output :summary
      end
    end

    contract_class = Class.new(Igniter::Contract) do
      define do
        input :technician_inputs, type: :array

        collection :technicians, with: :technician_inputs, each: failing_child, key: :technician_id, mode: :collect

        output :technicians
      end
    end

    contract = contract_class.new(technician_inputs: [
      { technician_id: 1 },
      { technician_id: 2 }
    ])

    contract.result.technicians

    event_types = contract.audit.events.map(&:type)
    failed_event = contract.audit.events.find { |event| event.type == :collection_item_failed }
    succeeded_event = contract.audit.events.find { |event| event.type == :collection_item_succeeded }

    expect(event_types).to include(:collection_item_started, :collection_item_succeeded, :collection_item_failed)
    expect(succeeded_event.payload).to include(item_key: 1)
    expect(failed_event.payload).to include(item_key: 2, error_type: "Igniter::ResolutionError")
    expect(failed_event.payload[:error]).to include("boom")
  end

  it "supports hash-like collection sources when map_inputs is used" do
    child = Class.new(Igniter::Contract) do
      define do
        input :company_id
        input :location_id

        compute :summary, with: %i[company_id location_id] do |company_id:, location_id:|
          { company_id: company_id, location_id: location_id }
        end

        output :summary
      end
    end

    contract_class = Class.new(Igniter::Contract) do
      define do
        input :locations_map

        collection :company_locations,
          with: :locations_map,
          each: child,
          key: :location_id,
          map_inputs: lambda { |item:|
            company_id, location_id = item
            { company_id: company_id, location_id: location_id }
          }

        output :company_locations
      end
    end

    contract = contract_class.new(locations_map: { "1" => "746", "2" => "1666" })
    result = contract.result.company_locations

    expect(result.keys).to eq(%w[746 1666])
    expect(result["746"].result.summary).to eq(company_id: "1", location_id: "746")
  end
end
