# frozen_string_literal: true

require "spec_helper"
require "json"
require_relative "../../igniter-lang/experiments/parser/igniter_lang_parser"

# Paths
PARSER_SOURCE_DIR  = File.expand_path("../../igniter-lang/source",         __dir__)
FIXTURE_DIR        = File.expand_path("../../igniter-lang/fixtures",        __dir__)
PARSER_GOLDEN_DIR  = File.expand_path("../../igniter-lang/fixtures/parser", __dir__)

def parse_ig(filename)
  path   = File.join(PARSER_SOURCE_DIR, filename)
  source = File.read(path)
  IgniterLang::ParsedProgram.parse(source, source_path: path)
end

def load_fixture_json(fixture_path)
  JSON.parse(File.read(fixture_path))
end

RSpec.describe "Parser Acceptance Harness — PROP-014 / PROP-015" do
  # ===========================================================================
  # Section 1: add.ig — CORE contract
  # ===========================================================================
  describe "add.ig" do
    let(:pp) { parse_ig("add.ig") }
    let(:ast) { pp.to_h }

    it "parses without errors" do
      expect(pp.valid?).to be true
      expect(pp.errors).to be_empty
    end

    it "kind: parsed_program" do
      expect(ast.fetch("kind")).to eq("parsed_program")
    end

    it "module: Lang.Examples.Add" do
      expect(ast.fetch("module")).to eq("Lang.Examples.Add")
    end

    it "has one contract: Add" do
      expect(ast.fetch("contracts").length).to eq(1)
      expect(ast.dig("contracts", 0, "name")).to eq("Add")
    end

    it "has two inputs: a and b (Integer)" do
      inputs = ast.dig("contracts", 0, "body").select { |d| d["kind"] == "input" }
      expect(inputs.map { |i| i["name"] }).to eq(["a", "b"])
      expect(inputs.map { |i| i["type_annotation"] }).to eq(["Integer", "Integer"])
    end

    it "has compute node: sum = a + b" do
      computes = ast.dig("contracts", 0, "body").select { |d| d["kind"] == "compute" }
      expect(computes.length).to eq(1)
      sum = computes.first
      expect(sum["name"]).to eq("sum")
      expect(sum.dig("expr", "kind")).to eq("binary_op")
      expect(sum.dig("expr", "op")).to eq("+")
      expect(sum.dig("expr", "left", "kind")).to eq("ref")
      expect(sum.dig("expr", "left", "name")).to eq("a")
      expect(sum.dig("expr", "right", "name")).to eq("b")
    end

    it "has output: sum: Integer" do
      outputs = ast.dig("contracts", 0, "body").select { |d| d["kind"] == "output" }
      expect(outputs.length).to eq(1)
      expect(outputs.first["name"]).to eq("sum")
      expect(outputs.first["type_annotation"]).to eq("Integer")
    end

    it "has no functions or types (CORE — stdlib only)" do
      expect(ast.fetch("functions")).to be_empty
      expect(ast.fetch("types")).to be_empty
    end

    it "source_hash is stable across re-parses" do
      pp2 = parse_ig("add.ig")
      expect(pp.source_hash).to eq(pp2.source_hash)
    end

    # --- Comparison path toward fixtures/add.igapp/ ---------------------------

    it "contract name matches fixtures/add.igapp/contracts/add.json contract_id" do
      fixture = load_fixture_json(File.join(FIXTURE_DIR, "add.igapp", "contracts", "add.json"))
      contract_name = ast.dig("contracts", 0, "name").downcase
      expect(fixture["contract_id"]).to eq(contract_name)
    end

    it "input port names match fixtures/add.igapp/ input_ports" do
      fixture = load_fixture_json(File.join(FIXTURE_DIR, "add.igapp", "contracts", "add.json"))
      fixture_inputs = fixture["input_ports"].map { |p| p["name"] }
      parsed_inputs  = ast.dig("contracts", 0, "body")
                          .select { |d| d["kind"] == "input" }
                          .map    { |d| d["name"] }
      expect(parsed_inputs).to eq(fixture_inputs)
    end

    it "input port type_tags match fixtures/add.igapp/" do
      fixture = load_fixture_json(File.join(FIXTURE_DIR, "add.igapp", "contracts", "add.json"))
      fixture_types = fixture["input_ports"].map { |p| p["type_tag"] }
      parsed_types  = ast.dig("contracts", 0, "body")
                         .select { |d| d["kind"] == "input" }
                         .map    { |d| d["type_annotation"] }
      expect(parsed_types).to eq(fixture_types)
    end

    it "output port name matches fixtures/add.igapp/" do
      fixture = load_fixture_json(File.join(FIXTURE_DIR, "add.igapp", "contracts", "add.json"))
      fixture_output_names = fixture["output_ports"].map { |p| p["name"] }
      parsed_output_names  = ast.dig("contracts", 0, "body")
                                .select { |d| d["kind"] == "output" }
                                .map    { |d| d["name"] }
      expect(parsed_output_names).to eq(fixture_output_names)
    end

    it "compute node expr is binary_op(+) — lowering path toward SemanticIR operator" do
      computes = ast.dig("contracts", 0, "body").select { |d| d["kind"] == "compute" }
      expr = computes.first["expr"]
      # ParsedProgram: binary_op with op: "+"
      expect(expr["kind"]).to eq("binary_op")
      expect(expr["op"]).to eq("+")
      # Fixture has a compute_node for "sum" confirming the expected output shape.
      # Lowering: binary_op(+, Integer, Integer) -> stdlib.numeric.add (Classify Pass 1).
      # The exact operator string in the fixture reflects the current devkit form;
      # after PROP-013 classifier is wired, it will resolve to "stdlib.numeric.add".
      fixture = load_fixture_json(File.join(FIXTURE_DIR, "add.igapp", "contracts", "add.json"))
      semantic_node = fixture["compute_nodes"].find { |n| n["name"] == "sum" }
      expect(semantic_node).not_to be_nil
      # The fixture expression operator is the SemanticIR-level operator (devkit form).
      expect(semantic_node["expression"]).to have_key("operator")
      # Parsed binary_op op "+" is the source-level representation of the same operation.
      expect(expr["op"]).to eq("+")
    end
  end

  # ===========================================================================
  # Section 2: availability_projection.ig — ESCAPE contract with window
  # ===========================================================================
  describe "availability_projection.ig" do
    let(:pp) { parse_ig("availability_projection.ig") }
    let(:ast) { pp.to_h }

    it "parses without errors" do
      expect(pp.valid?).to be true
      expect(pp.errors).to be_empty
    end

    it "module: SparkCRM.Availability" do
      expect(ast.fetch("module")).to eq("SparkCRM.Availability")
    end

    it "has one import: SparkCRM.Types with 4 names" do
      expect(ast.fetch("imports").length).to eq(1)
      imp = ast.fetch("imports").first
      expect(imp["module_path"]).to eq("SparkCRM.Types")
      expect(imp["names"]).to include("GeoSignal", "TimeSlot", "ScheduleFact", "AvailabilitySnapshot")
    end

    it "has two functions: compute_slots and build_snapshot" do
      fns = ast.fetch("functions")
      expect(fns.map { |f| f["name"] }).to eq(["compute_slots", "build_snapshot"])
    end

    describe "compute_slots function" do
      let(:fn) { ast["functions"].find { |f| f["name"] == "compute_slots" } }

      it "has 2 params: geo_signals and schedule" do
        expect(fn["params"].map { |p| p["name"] }).to eq(["geo_signals", "schedule"])
      end

      it "param type_annotations: Collection[GeoSignal] and ScheduleFact" do
        expect(fn.dig("params", 0, "type_annotation")).to eq({ "kind" => "type_ref", "name" => "Collection", "params" => [{ "kind" => "type_ref", "name" => "GeoSignal", "params" => [] }] })
        expect(fn.dig("params", 1, "type_annotation")).to eq("ScheduleFact")
      end

      it "return_type: Collection[TimeSlot]" do
        expect(fn["return_type"]).to eq({ "kind" => "type_ref", "name" => "Collection", "params" => [{ "kind" => "type_ref", "name" => "TimeSlot", "params" => [] }] })
      end

      it "body return_expr is if_expr" do
        expect(fn.dig("body", "return_expr", "kind")).to eq("if_expr")
      end

      it "if cond is field_access: schedule.day_off" do
        cond = fn.dig("body", "return_expr", "cond")
        expect(cond["kind"]).to eq("field_access")
        expect(cond["field"]).to eq("day_off")
        expect(cond.dig("object", "name")).to eq("schedule")
      end

      it "else branch contains a fold call" do
        # else branch stmts contain let start, let end; return_expr is fold(...)
        else_body = fn.dig("body", "return_expr", "else")
        ret = else_body["return_expr"]
        expect(ret["kind"]).to eq("call")
        expect(ret["fn"]).to eq("fold")
      end

      it "fold first arg is range(start, end)" do
        else_body = fn.dig("body", "return_expr", "else")
        fold_args = else_body.dig("return_expr", "args")
        range_arg = fold_args.first
        expect(range_arg["kind"]).to eq("call")
        expect(range_arg["fn"]).to eq("range")
      end

      it "fold lambda captures acc and hour params" do
        else_body = fn.dig("body", "return_expr", "else")
        fold_args = else_body.dig("return_expr", "args")
        lambda_arg = fold_args.last
        expect(lambda_arg["kind"]).to eq("lambda")
        expect(lambda_arg["params"]).to eq(["acc", "hour"])
      end
    end

    describe "build_snapshot function" do
      let(:fn) { ast["functions"].find { |f| f["name"] == "build_snapshot" } }

      it "has 3 params: slots, technician_id, date" do
        expect(fn["params"].map { |p| p["name"] }).to eq(["slots", "technician_id", "date"])
      end

      it "return_type: AvailabilitySnapshot" do
        expect(fn["return_type"]).to eq("AvailabilitySnapshot")
      end

      it "body has let stmt: available_count = count(filter(...))" do
        stmts = fn.dig("body", "stmts")
        expect(stmts.length).to eq(1)
        let_stmt = stmts.first
        expect(let_stmt["kind"]).to eq("let")
        expect(let_stmt["name"]).to eq("available_count")
        expr = let_stmt["expr"]
        expect(expr["kind"]).to eq("call")
        expect(expr["fn"]).to eq("count")
      end

      it "return_expr is record_literal with 5 fields" do
        ret = fn.dig("body", "return_expr")
        expect(ret["kind"]).to eq("record_literal")
        expect(ret["fields"].keys).to include(
          "technician_id", "date", "available_slots", "available_count", "snapshot_at"
        )
      end
    end

    describe "AvailabilityProjection contract" do
      let(:contract) { ast["contracts"].find { |c| c["name"] == "AvailabilityProjection" } }
      let(:body)     { contract["body"] }

      it "has contract: AvailabilityProjection" do
        expect(contract).not_to be_nil
      end

      it "has 2 inputs: technician_id and date (String)" do
        inputs = body.select { |d| d["kind"] == "input" }
        expect(inputs.map { |i| i["name"] }).to eq(["technician_id", "date"])
        expect(inputs.map { |i| i["type_annotation"] }.uniq).to eq(["String"])
      end

      it "has escape declaration: stream_collection" do
        escapes = body.select { |d| d["kind"] == "escape" }
        expect(escapes.map { |e| e["name"] }).to include("stream_collection")
      end

      it "has 2 read nodes with lifecycle annotations" do
        reads = body.select { |d| d["kind"] == "read" }
        expect(reads.length).to eq(2)
        geo = reads.find { |r| r["name"] == "geo_signals" }
        sched = reads.find { |r| r["name"] == "schedule" }
        expect(geo).not_to be_nil
        expect(sched).not_to be_nil
        expect(geo["lifecycle"]).to eq("window")
        expect(sched["lifecycle"]).to eq("durable")
      end

      it "geo_signals read type: Collection[GeoSignal]" do
        geo = body.find { |d| d["kind"] == "read" && d["name"] == "geo_signals" }
        expect(geo["type_annotation"]).to eq({ "kind" => "type_ref", "name" => "Collection", "params" => [{ "kind" => "type_ref", "name" => "GeoSignal", "params" => [] }] })
      end

      it "geo_signals from template includes technician_id and date" do
        geo = body.find { |d| d["kind"] == "read" && d["name"] == "geo_signals" }
        expect(geo["from"]).to include("technician_id").and include("date")
      end

      it "has compute node: available_slots = compute_slots(...)" do
        computes = body.select { |d| d["kind"] == "compute" }
        expect(computes.length).to eq(1)
        node = computes.first
        expect(node["name"]).to eq("available_slots")
        expect(node.dig("expr", "kind")).to eq("call")
        expect(node.dig("expr", "fn")).to eq("compute_slots")
      end

      it "compute_slots call args reference geo_signals and schedule" do
        compute = body.find { |d| d["kind"] == "compute" && d["name"] == "available_slots" }
        arg_names = compute.dig("expr", "args").map { |a| a["name"] }
        expect(arg_names).to eq(["geo_signals", "schedule"])
      end

      it "has window declaration with calendar/day/snapshot options" do
        windows = body.select { |d| d["kind"] == "window" }
        expect(windows.length).to eq(1)
        win = windows.first
        expect(win["label"]).to include("availability")
        expect(win.dig("options", "kind")).to eq("calendar")
        expect(win.dig("options", "unit")).to eq("day")
        expect(win.dig("options", "on_close")).to eq("snapshot")
      end

      it "has snapshot node: snap = build_snapshot(...) lifecycle :durable" do
        snaps = body.select { |d| d["kind"] == "snapshot" }
        expect(snaps.length).to eq(1)
        snap = snaps.first
        expect(snap["name"]).to eq("snap")
        expect(snap["lifecycle"]).to eq("durable")
        expect(snap.dig("expr", "fn")).to eq("build_snapshot")
      end

      it "has 2 outputs with lifecycle annotations" do
        outputs = body.select { |d| d["kind"] == "output" }
        expect(outputs.length).to eq(2)
        slots_out = outputs.find { |o| o["name"] == "available_slots" }
        snap_out  = outputs.find { |o| o["name"] == "snap" }
        expect(slots_out["lifecycle"]).to eq("window")
        expect(snap_out["lifecycle"]).to eq("durable")
      end

      # --- Comparison path toward fixtures/availability_projection.igapp/ ---

      it "contract name maps to fixture contract_id" do
        fixture_path = File.join(FIXTURE_DIR, "availability_projection.igapp",
                                 "contracts", "availability_projection.json")
        if File.exist?(fixture_path)
          fixture = load_fixture_json(fixture_path)
          expect(fixture["contract_id"]).to eq("availability_projection")
        else
          skip "availability_projection.igapp fixture not yet present at expected path"
        end
      end

      it "escape_set from source matches fixture escape_set" do
        fixture_path = File.join(FIXTURE_DIR, "availability_projection.igapp",
                                 "contracts", "availability_projection.json")
        if File.exist?(fixture_path)
          fixture = load_fixture_json(fixture_path)
          parsed_escapes = body.select { |d| d["kind"] == "escape" }.map { |e| e["name"] }
          expect(parsed_escapes).to eq(fixture["escape_set"])
        else
          skip "availability_projection.igapp fixture not yet present at expected path"
        end
      end
    end
  end

  # ===========================================================================
  # Section 3: ParsedProgram structure invariants (both files)
  # ===========================================================================
  describe "ParsedProgram structural invariants" do
    %w[add.ig availability_projection.ig].each do |filename|
      describe filename do
        let(:pp)  { parse_ig(filename) }
        let(:ast) { pp.to_h }

        it "has grammar_version 0.1.0" do
          expect(ast.fetch("grammar_version")).to eq("0.1.0")
        end

        it "source_hash starts with sha256:" do
          expect(ast.fetch("source_hash")).to start_with("sha256:")
        end

        it "module is a String or nil" do
          mod = ast.fetch("module")
          expect(mod).to be_a(String).or be_nil
        end

        it "imports is an Array" do
          expect(ast.fetch("imports")).to be_an(Array)
        end

        it "contracts is a non-empty Array" do
          expect(ast.fetch("contracts")).to be_an(Array)
          expect(ast.fetch("contracts")).not_to be_empty
        end

        it "all contracts have kind: contract" do
          ast.fetch("contracts").each do |c|
            expect(c["kind"]).to eq("contract")
          end
        end

        it "all body nodes have a kind field" do
          ast.fetch("contracts").each do |contract|
            contract.fetch("body").each do |node|
              expect(node).to have_key("kind"), "body node missing 'kind': #{node.inspect}"
            end
          end
        end

        it "all functions have kind, name, params, return_type, body" do
          ast.fetch("functions").each do |fn|
            %w[kind name params return_type body].each do |key|
              expect(fn).to have_key(key), "function missing key: #{key}"
            end
            expect(fn["kind"]).to eq("function")
          end
        end

        it "parse_errors is empty (no syntax errors)" do
          expect(ast.fetch("parse_errors")).to be_empty
        end
      end
    end
  end
end
