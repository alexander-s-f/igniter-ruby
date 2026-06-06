# frozen_string_literal: true

require "igniter"
require "igniter/extensions/differential"

RSpec.describe "Igniter Differential Execution" do
  # ── Shared contract fixtures ───────────────────────────────────────────────

  let(:base_contract) do
    Class.new(Igniter::Contract) do
      define do
        input :price,    type: :numeric
        input :quantity, type: :numeric

        compute :subtotal, depends_on: %i[price quantity] do |price:, quantity:|
          (price * quantity).round(2)
        end

        compute :tax, depends_on: :subtotal do |subtotal:|
          (subtotal * 0.10).round(2)
        end

        compute :total, depends_on: %i[subtotal tax] do |subtotal:, tax:|
          subtotal + tax
        end

        output :subtotal
        output :tax
        output :total
      end
    end
  end

  # Candidate with higher tax rate but same output names
  let(:higher_tax_contract) do
    Class.new(Igniter::Contract) do
      define do
        input :price,    type: :numeric
        input :quantity, type: :numeric

        compute :subtotal, depends_on: %i[price quantity] do |price:, quantity:|
          (price * quantity).round(2)
        end

        compute :tax, depends_on: :subtotal do |subtotal:|
          (subtotal * 0.20).round(2)   # doubled
        end

        compute :total, depends_on: %i[subtotal tax] do |subtotal:, tax:|
          subtotal + tax
        end

        output :subtotal
        output :tax
        output :total
      end
    end
  end

  # Candidate with an extra output absent in base
  let(:extra_output_contract) do
    Class.new(Igniter::Contract) do
      define do
        input :price,    type: :numeric
        input :quantity, type: :numeric

        compute :subtotal, depends_on: %i[price quantity] do |price:, quantity:|
          (price * quantity).round(2)
        end

        compute :tax, depends_on: :subtotal do |subtotal:|
          (subtotal * 0.10).round(2)
        end

        compute :discount, depends_on: :subtotal do |subtotal:|
          subtotal > 100 ? 10.0 : 0.0
        end

        compute :total, depends_on: %i[subtotal tax discount] do |subtotal:, tax:, discount:|
          subtotal + tax - discount
        end

        output :subtotal
        output :tax
        output :discount   # extra
        output :total
      end
    end
  end

  let(:inputs) { { price: 50.0, quantity: 3 } }

  # ── Igniter::Differential.compare ─────────────────────────────────────────

  describe "Igniter::Differential.compare" do
    context "when both contracts produce identical outputs" do
      it "returns a matching report" do
        report = Igniter::Differential.compare(
          primary: base_contract,
          candidate: base_contract,
          inputs: inputs
        )
        expect(report.match?).to be true
      end

      it "has no divergences and no asymmetric outputs" do
        report = Igniter::Differential.compare(
          primary: base_contract,
          candidate: base_contract,
          inputs: inputs
        )
        expect(report.divergences).to be_empty
        expect(report.primary_only).to be_empty
        expect(report.candidate_only).to be_empty
      end
    end

    context "when candidate has different output values" do
      subject(:report) do
        Igniter::Differential.compare(
          primary: base_contract,
          candidate: higher_tax_contract,
          inputs: inputs
        )
      end

      it "returns a non-matching report" do
        expect(report.match?).to be false
      end

      it "captures a divergence for the differing output" do
        div = report.divergences.find { |d| d.output_name == :tax }
        expect(div).not_to be_nil
        expect(div.primary_value).to eq 15.0
        expect(div.candidate_value).to eq 30.0
      end

      it "computes the correct numeric delta" do
        div = report.divergences.find { |d| d.output_name == :tax }
        expect(div.delta).to eq 15.0
      end

      it "reports :value_mismatch kind for same-type divergence" do
        div = report.divergences.first
        expect(div.kind).to eq :value_mismatch
      end

      it "also captures the total divergence" do
        names = report.divergences.map(&:output_name)
        expect(names).to include(:tax, :total)
      end

      it "reports subtotal as matching (shared correct output)" do
        names = report.divergences.map(&:output_name)
        expect(names).not_to include(:subtotal)
      end
    end

    context "when candidate has an extra output not in primary" do
      subject(:report) do
        Igniter::Differential.compare(
          primary: base_contract,
          candidate: extra_output_contract,
          inputs: inputs
        )
      end

      it "records the extra output in candidate_only" do
        expect(report.candidate_only.keys).to include(:discount)
      end

      it "includes the candidate output value" do
        # subtotal = 50.0 * 3 = 150.0 > 100 → discount = 10.0
        expect(report.candidate_only[:discount]).to eq 10.0
      end

      it "leaves primary_only empty" do
        expect(report.primary_only).to be_empty
      end
    end

    context "when primary has an extra output not in candidate" do
      subject(:report) do
        Igniter::Differential.compare(
          primary: extra_output_contract,
          candidate: base_contract,
          inputs: inputs
        )
      end

      it "records the extra output in primary_only" do
        expect(report.primary_only.keys).to include(:discount)
      end

      it "leaves candidate_only empty" do
        expect(report.candidate_only).to be_empty
      end
    end

    context "with numeric tolerance" do
      subject(:report) do
        Igniter::Differential.compare(
          primary: base_contract,
          candidate: higher_tax_contract,
          inputs: inputs,
          tolerance: 20.0   # tax difference is 15, within tolerance
        )
      end

      it "treats values within tolerance as matching" do
        div_names = report.divergences.map(&:output_name)
        expect(div_names).not_to include(:tax)
      end

      it "treats values outside tolerance as diverged" do
        # total differs by 15 (within 20 tolerance) — should also pass
        expect(report.divergences.map(&:output_name)).not_to include(:total)
      end

      it "returns matching when all differences are within tolerance" do
        expect(report.match?).to be true
      end

      it "still reports divergence when difference exceeds tolerance" do
        report_tight = Igniter::Differential.compare(
          primary: base_contract,
          candidate: higher_tax_contract,
          inputs: inputs,
          tolerance: 5.0   # tax differs by 15, exceeds 5
        )
        div_names = report_tight.divergences.map(&:output_name)
        expect(div_names).to include(:tax)
      end
    end

    context "when candidate raises an error during execution" do
      let(:broken_candidate) do
        Class.new(Igniter::Contract) do
          define do
            input :price, type: :numeric
            input :quantity, type: :numeric

            compute :subtotal, depends_on: %i[price quantity] do |**|
              raise "database unavailable"
            end

            output :subtotal
          end
        end
      end

      subject(:report) do
        Igniter::Differential.compare(
          primary: base_contract,
          candidate: broken_candidate,
          inputs: inputs
        )
      end

      it "captures the candidate error" do
        expect(report.candidate_error).to be_a(Igniter::Error)
      end

      it "returns a non-matching report" do
        expect(report.match?).to be false
      end

      it "still resolves the primary successfully" do
        expect(report.primary_error).to be_nil
      end
    end

    context "when primary raises an error during execution" do
      let(:broken_primary) do
        Class.new(Igniter::Contract) do
          define do
            input :price, type: :numeric
            input :quantity, type: :numeric

            compute :subtotal, depends_on: %i[price quantity] do |**|
              raise "unexpected failure"
            end

            output :subtotal
          end
        end
      end

      subject(:report) do
        Igniter::Differential.compare(
          primary: broken_primary,
          candidate: base_contract,
          inputs: inputs
        )
      end

      it "captures the primary error" do
        expect(report.primary_error).to be_a(Igniter::Error)
      end

      it "still tries the candidate" do
        expect(report.candidate_error).to be_nil
      end
    end
  end

  # ── Igniter::Differential::Report ─────────────────────────────────────────

  describe "Igniter::Differential::Report" do
    subject(:report) do
      Igniter::Differential.compare(
        primary: base_contract,
        candidate: higher_tax_contract,
        inputs: inputs
      )
    end

    it "#summary returns a short descriptive string" do
      expect(report.summary).to include("diverged")
    end

    it "#explain returns readable text" do
      text = report.explain
      expect(text).to include("Primary")
      expect(text).to include("Candidate")
      expect(text).to include("DIVERGENCES")
    end

    it "#to_s aliases #explain" do
      expect(report.to_s).to eq(report.explain)
    end

    it "#to_h returns a serialisable Hash" do
      h = report.to_h
      expect(h[:match]).to be false
      expect(h[:divergences]).to be_an(Array)
      expect(h[:divergences].first).to include(:output, :primary, :candidate)
    end

    describe "#match?" do
      it "returns true for identical contracts" do
        matching = Igniter::Differential.compare(
          primary: base_contract,
          candidate: base_contract,
          inputs: inputs
        )
        expect(matching.match?).to be true
      end

      it "returns false when there are divergences" do
        expect(report.match?).to be false
      end
    end

    it "is frozen (immutable)" do
      expect(report).to be_frozen
    end
  end

  # ── Igniter::Differential::Divergence ─────────────────────────────────────

  describe "Igniter::Differential::Divergence" do
    subject(:div) do
      Igniter::Differential.compare(
        primary: base_contract,
        candidate: higher_tax_contract,
        inputs: inputs
      ).divergences.find { |d| d.output_name == :tax }
    end

    it "has the correct output_name" do
      expect(div.output_name).to eq :tax
    end

    it "computes a numeric delta" do
      expect(div.delta).to eq 15.0
    end

    it "is :value_mismatch for same-type divergence" do
      expect(div.kind).to eq :value_mismatch
    end

    it "returns nil delta for non-numeric values" do
      str_primary = Class.new(Igniter::Contract) do
        define do
          input :x
          compute :label, depends_on: :x do |x:| "#{x}" end
          output :label
        end
      end
      str_candidate = Class.new(Igniter::Contract) do
        define do
          input :x
          compute :label, depends_on: :x do |x:| "value:#{x}" end
          output :label
        end
      end
      report = Igniter::Differential.compare(
        primary: str_primary,
        candidate: str_candidate,
        inputs: { x: 42 }
      )
      string_div = report.divergences.find { |d| d.output_name == :label }
      expect(string_div.delta).to be_nil
    end

    it "is :type_mismatch when types differ" do
      num_primary = Class.new(Igniter::Contract) do
        define do
          input :x
          compute :result, depends_on: :x do |x:| x.to_i end
          output :result
        end
      end
      str_candidate = Class.new(Igniter::Contract) do
        define do
          input :x
          compute :result, depends_on: :x do |x:| x.to_s end
          output :result
        end
      end
      report = Igniter::Differential.compare(
        primary: num_primary,
        candidate: str_candidate,
        inputs: { x: 42 }
      )
      expect(report.divergences.first.kind).to eq :type_mismatch
    end

    it "is frozen" do
      expect(div).to be_frozen
    end
  end

  # ── #diff_against instance method ─────────────────────────────────────────

  describe "#diff_against" do
    it "compares an already-resolved contract against a candidate" do
      contract = base_contract.new(inputs)
      contract.resolve_all
      report = contract.diff_against(higher_tax_contract)

      expect(report.match?).to be false
      expect(report.divergences.map(&:output_name)).to include(:tax)
    end

    it "returns a matching report when candidate is identical" do
      contract = base_contract.new(inputs)
      contract.resolve_all
      report = contract.diff_against(base_contract)

      expect(report.match?).to be true
    end

    it "raises DifferentialError if resolve_all has not been called" do
      contract = base_contract.new(inputs)
      expect { contract.diff_against(higher_tax_contract) }
        .to raise_error(Igniter::Differential::DifferentialError, /resolve_all/)
    end

    it "accepts a tolerance parameter" do
      contract = base_contract.new(inputs)
      contract.resolve_all
      report = contract.diff_against(higher_tax_contract, tolerance: 100.0)
      expect(report.match?).to be true
    end
  end

  # ── shadow_with class-level DSL ───────────────────────────────────────────

  describe "shadow_with" do
    let(:divergence_reports) { [] }

    let(:shadow_contract_class) do
      collector = divergence_reports
      primary = base_contract
      candidate = higher_tax_contract

      Class.new(Igniter::Contract) do
        shadow_with candidate, on_divergence: ->(r) { collector << r }
        define do
          input :price,    type: :numeric
          input :quantity, type: :numeric

          compute :subtotal, depends_on: %i[price quantity] do |price:, quantity:|
            (price * quantity).round(2)
          end

          compute :tax, depends_on: :subtotal do |subtotal:|
            (subtotal * 0.10).round(2)
          end

          compute :total, depends_on: %i[subtotal tax] do |subtotal:, tax:|
            subtotal + tax
          end

          output :subtotal
          output :tax
          output :total
        end
      end
    end

    it "automatically runs the candidate after resolve_all" do
      contract = shadow_contract_class.new(inputs)
      contract.resolve_all
      expect(divergence_reports.size).to eq 1
    end

    it "calls on_divergence when outputs differ" do
      contract = shadow_contract_class.new(inputs)
      contract.resolve_all
      expect(divergence_reports.first.match?).to be false
    end

    it "does not call on_divergence when primary and candidate match" do
      collector = divergence_reports
      matching_class = Class.new(Igniter::Contract) do
        shadow_with(
          Class.new(Igniter::Contract) do
            define do
              input :price, type: :numeric
              input :quantity, type: :numeric
              compute :total, depends_on: %i[price quantity] do |price:, quantity:|
                (price * quantity).round(2)
              end
              output :total
            end
          end,
          on_divergence: ->(r) { collector << r }
        )
        define do
          input :price, type: :numeric
          input :quantity, type: :numeric
          compute :total, depends_on: %i[price quantity] do |price:, quantity:|
            (price * quantity).round(2)
          end
          output :total
        end
      end

      contract = matching_class.new(inputs)
      contract.resolve_all
      expect(divergence_reports).to be_empty
    end

    it "does not trigger recursive shadow when runner executes the primary internally" do
      # If the skip-shadow flag fails, the inner runner would call shadow again
      # causing infinite recursion. This test confirms it terminates.
      counter = []
      cls = Class.new(Igniter::Contract) do
        shadow_with(
          Class.new(Igniter::Contract) do
            define do
              input :x
              compute :y, depends_on: :x do |x:| x * 2 end
              output :y
            end
          end,
          on_divergence: ->(r) { counter << r }
        )
        define do
          input :x
          compute :y, depends_on: :x do |x:| x * 3 end
          output :y
        end
      end

      expect { cls.new(x: 5).resolve_all }.not_to raise_error
      expect(counter.size).to eq 1  # triggered exactly once
    end

    it "exposes shadow_candidate and related accessors on the class" do
      candidate_cls = higher_tax_contract
      cls = Class.new(Igniter::Contract) do
        shadow_with candidate_cls, async: true, tolerance: 0.01
        define { input :x; output :x }
      end

      expect(cls.shadow_candidate).to eq candidate_cls
      expect(cls.shadow_async?).to be true
      expect(cls.shadow_tolerance).to eq 0.01
    end

    it "still returns the primary contract result from resolve_all" do
      contract = shadow_contract_class.new(inputs)
      result = contract.resolve_all
      expect(result).to eq contract   # resolve_all returns self
      expect(contract.result.total).to eq 165.0
    end
  end

  # ── Formatter ─────────────────────────────────────────────────────────────

  describe "Igniter::Differential::Formatter" do
    subject(:text) do
      Igniter::Differential.compare(
        primary: base_contract,
        candidate: higher_tax_contract,
        inputs: inputs
      ).explain
    end

    it "includes primary and candidate class names" do
      expect(text).to include("Primary:")
      expect(text).to include("Candidate:")
    end

    it "shows Match: NO for diverging contracts" do
      expect(text).to include("Match:      NO")
    end

    it "shows Match: YES for identical contracts" do
      matching = Igniter::Differential.compare(
        primary: base_contract,
        candidate: base_contract,
        inputs: inputs
      )
      expect(matching.explain).to include("Match:      YES")
    end

    it "includes DIVERGENCES section with output names" do
      expect(text).to include("DIVERGENCES")
      expect(text).to include(":tax")
    end

    it "shows delta value for numeric divergences" do
      expect(text).to match(/delta:\s+\+?[\d.]+/)
    end

    it "shows CANDIDATE ONLY section when candidate has extra outputs" do
      report = Igniter::Differential.compare(
        primary: base_contract,
        candidate: extra_output_contract,
        inputs: inputs
      )
      expect(report.explain).to include("CANDIDATE ONLY")
      expect(report.explain).to include(":discount")
    end
  end
end
