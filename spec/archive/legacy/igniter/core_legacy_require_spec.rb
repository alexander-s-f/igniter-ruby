# frozen_string_literal: true

require "spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "Igniter legacy core entrypoints" do
  LEGACY_ROOT = File.expand_path("../..", __dir__)

  def bundled_load_path_script(entrypoint)
    <<~RUBY
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-core/lib", #{LEGACY_ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-contracts/lib", #{LEGACY_ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("packages/igniter-extensions/lib", #{LEGACY_ROOT.inspect}))
      $LOAD_PATH.unshift(File.expand_path("lib", #{LEGACY_ROOT.inspect}))
      require #{entrypoint.inspect}
    RUBY
  end

  def capture_require(entrypoint, env: {})
    Open3.capture3(
      env,
      RbConfig.ruby,
      "-e",
      bundled_load_path_script(entrypoint),
      chdir: LEGACY_ROOT
    )
  end

  it "warns when loading igniter/core by default" do
    _stdout, stderr, status = capture_require(
      "igniter/core",
      env: { "IGNITER_LEGACY_CORE_REQUIRE" => nil }
    )

    expect(status.success?).to eq(true)
    expect(stderr).to include("legacy reference implementation")
    expect(stderr).to include("igniter/core")
    expect(stderr).to include("igniter-contracts")
  end

  it "does not emit a legacy core warning for the explicit igniter/legacy lane" do
    _stdout, stderr, status = capture_require(
      "igniter/legacy",
      env: { "IGNITER_LEGACY_CORE_REQUIRE" => nil }
    )

    expect(status.success?).to eq(true)
    expect(stderr).not_to include("legacy reference implementation")
    expect(stderr).not_to include("igniter-core")
  end

  it "does not emit a legacy core warning for the igniter-legacy gem facade" do
    _stdout, stderr, status = capture_require(
      "igniter-legacy",
      env: { "IGNITER_LEGACY_CORE_REQUIRE" => nil }
    )

    expect(status.success?).to eq(true)
    expect(stderr).not_to include("legacy reference implementation")
    expect(stderr).not_to include("igniter-core")
  end

  it "can fail fast for legacy core entrypoints in strict mode" do
    _stdout, stderr, status = capture_require(
      "igniter/core/tool",
      env: { "IGNITER_LEGACY_CORE_REQUIRE" => "error" }
    )

    expect(status.success?).to eq(false)
    expect(stderr).to include("Igniter::Core::Legacy::RequireError")
    expect(stderr).to include("igniter/core/tool")
  end

  it "warns when loading a legacy core-backed extension activator" do
    _stdout, stderr, status = capture_require(
      "igniter/extensions/execution_report",
      env: { "IGNITER_LEGACY_CORE_REQUIRE" => nil }
    )

    expect(status.success?).to eq(true)
    expect(stderr).to include("legacy core-backed extension activator")
    expect(stderr).to include("igniter/extensions/execution_report")
    expect(stderr).to include("Igniter::Extensions::Contracts::ExecutionReportPack")
  end

  it "can fail fast for legacy extension activators in strict mode" do
    _stdout, stderr, status = capture_require(
      "igniter/extensions/dataflow",
      env: { "IGNITER_LEGACY_CORE_REQUIRE" => "error" }
    )

    expect(status.success?).to eq(false)
    expect(stderr).to include("Igniter::Extensions::Legacy::RequireError")
    expect(stderr).to include("igniter/extensions/dataflow")
  end

  it "mentions the contracts replacement for legacy dataflow activators" do
    _stdout, stderr, status = capture_require(
      "igniter/extensions/dataflow",
      env: { "IGNITER_LEGACY_CORE_REQUIRE" => nil }
    )

    expect(status.success?).to eq(true)
    expect(stderr).to include("Igniter::Extensions::Contracts::DataflowPack")
  end

  it "mentions the contracts replacement for legacy auditing activators" do
    _stdout, stderr, status = capture_require(
      "igniter/extensions/auditing",
      env: { "IGNITER_LEGACY_CORE_REQUIRE" => nil }
    )

    expect(status.success?).to eq(true)
    expect(stderr).to include("Igniter::Extensions::Contracts::AuditPack")
  end

  it "mentions the contracts replacement for legacy reactive activators" do
    _stdout, stderr, status = capture_require(
      "igniter/extensions/reactive",
      env: { "IGNITER_LEGACY_CORE_REQUIRE" => nil }
    )

    expect(status.success?).to eq(true)
    expect(stderr).to include("Igniter::Extensions::Contracts::ReactivePack")
  end

  it "mentions the contracts replacement for legacy invariants activators" do
    _stdout, stderr, status = capture_require(
      "igniter/extensions/invariants",
      env: { "IGNITER_LEGACY_CORE_REQUIRE" => nil }
    )

    expect(status.success?).to eq(true)
    expect(stderr).to include("Igniter::Extensions::Contracts::InvariantsPack")
  end

  it "mentions the contracts replacement for legacy capabilities activators" do
    _stdout, stderr, status = capture_require(
      "igniter/extensions/capabilities",
      env: { "IGNITER_LEGACY_CORE_REQUIRE" => nil }
    )

    expect(status.success?).to eq(true)
    expect(stderr).to include("Igniter::Extensions::Contracts::CapabilitiesPack")
  end

  it "mentions the contracts replacement for legacy content-addressing activators" do
    _stdout, stderr, status = capture_require(
      "igniter/extensions/content_addressing",
      env: { "IGNITER_LEGACY_CORE_REQUIRE" => nil }
    )

    expect(status.success?).to eq(true)
    expect(stderr).to include("Igniter::Extensions::Contracts::ContentAddressingPack")
  end

  it "does not emit a legacy core warning for the contracts-facing extensions facade" do
    _stdout, stderr, status = capture_require(
      "igniter/extensions/contracts",
      env: { "IGNITER_LEGACY_CORE_REQUIRE" => nil }
    )

    expect(status.success?).to eq(true)
    expect(stderr).not_to include("legacy reference implementation")
    expect(stderr).not_to include("igniter-core")
  end

  it "does not emit a legacy core warning for the package root facade alone" do
    _stdout, stderr, status = capture_require(
      "igniter-extensions",
      env: { "IGNITER_LEGACY_CORE_REQUIRE" => nil }
    )

    expect(status.success?).to eq(true)
    expect(stderr).not_to include("legacy reference implementation")
    expect(stderr).not_to include("igniter-core")
  end

  it "does not emit a legacy core warning for require \"igniter\"" do
    _stdout, stderr, status = capture_require(
      "igniter",
      env: { "IGNITER_LEGACY_CORE_REQUIRE" => nil }
    )

    expect(status.success?).to eq(true)
    expect(stderr).not_to include("legacy reference implementation")
    expect(stderr).not_to include("igniter-core")
  end

  it "does not emit a legacy core warning for upper package entrypoints that use the explicit legacy lane" do
    _stdout, stderr, status = capture_require(
      "igniter/cluster",
      env: { "IGNITER_LEGACY_CORE_REQUIRE" => nil }
    )

    expect(status.success?).to eq(true)
    expect(stderr).not_to include("legacy reference implementation")
    expect(stderr).not_to include("igniter-core")
  end

  it "does not emit a legacy core warning for stable shared entrypoints" do
    _stdout, stderr, status = capture_require(
      "igniter/tool",
      env: { "IGNITER_LEGACY_CORE_REQUIRE" => nil }
    )

    expect(status.success?).to eq(true)
    expect(stderr).not_to include("legacy reference implementation")
    expect(stderr).not_to include("igniter-core")
  end

  it "does not emit a legacy core warning for sdk and ai entrypoints that use stable shared primitives" do
    _stdout, stderr, status = capture_require(
      "igniter/ai",
      env: { "IGNITER_LEGACY_CORE_REQUIRE" => nil }
    )

    expect(status.success?).to eq(true)
    expect(stderr).not_to include("legacy reference implementation")
    expect(stderr).not_to include("igniter-core")
  end

  it "does not emit a legacy core warning for agent entrypoints that use stable runtime seams" do
    _stdout, stderr, status = capture_require(
      "igniter/agent",
      env: { "IGNITER_LEGACY_CORE_REQUIRE" => nil }
    )

    expect(status.success?).to eq(true)
    expect(stderr).not_to include("legacy reference implementation")
    expect(stderr).not_to include("igniter-core")
  end
end
