# frozen_string_literal: true

require_relative "../spec_helper"
require "open3"
require "rbconfig"

RSpec.describe "igniter-ledger rename compatibility" do
  PACKAGE_ROOT = File.expand_path("../..", __dir__)
  LIB_DIR = File.join(PACKAGE_ROOT, "lib")
  EXE_DIR = File.join(PACKAGE_ROOT, "exe")

  def run_ruby(*args)
    Open3.capture3(RbConfig.ruby, *args)
  end

  def expect_success(stdout, stderr, status)
    expect(status).to be_success, "expected success\nstdout:\n#{stdout}\nstderr:\n#{stderr}"
  end

  it "loads the package through the new require entrypoint" do
    stdout, stderr, status = run_ruby(
      "-I", LIB_DIR,
      "-e", <<~RUBY
        require "igniter-ledger"
        store = Igniter::Ledger::LedgerStore.new
        store.write(store: :compat, key: "new", value: { ok: true })
        abort "missing ledger read" unless store.read(store: :compat, key: "new") == { ok: true }
        puts Igniter::Ledger::LedgerStore.name
      RUBY
    )

    expect_success(stdout, stderr, status)
    expect(stdout).to include("Igniter::Store::IgniterStore")
  end

  it "loads the package through the old require entrypoint" do
    stdout, stderr, status = run_ruby(
      "-I", LIB_DIR,
      "-e", <<~RUBY
        require "igniter-store"
        store = Igniter::Store::LedgerStore.new
        store.write(store: :compat, key: "old", value: { ok: true })
        abort "missing store read" unless store.read(store: :compat, key: "old") == { ok: true }
        puts Igniter::Store::LedgerStore.name
      RUBY
    )

    expect_success(stdout, stderr, status)
    expect(stdout).to include("Igniter::Store::IgniterStore")
  end

  it "keeps new and old store constructor aliases usable" do
    ledger_store = Igniter::Ledger::LedgerStore.new
    store_alias = Igniter::Store::LedgerStore.new

    ledger_store.write(store: :tasks, key: "l1", value: { title: "ledger" })
    store_alias.write(store: :tasks, key: "s1", value: { title: "store" })

    expect(ledger_store.read(store: :tasks, key: "l1")).to eq(title: "ledger")
    expect(store_alias.read(store: :tasks, key: "s1")).to eq(title: "store")
  end

  it "keeps old and new memory factories usable" do
    old_store = Igniter::Store.memory
    new_store = Igniter::Ledger.memory

    old_store.write(store: :tasks, key: "old", value: { source: :store })
    new_store.write(store: :tasks, key: "new", value: { source: :ledger })

    expect(old_store.read(store: :tasks, key: "old")).to eq(source: :store)
    expect(new_store.read(store: :tasks, key: "new")).to eq(source: :ledger)
  end

  it "resolves LedgerServer and network backend through compatibility aliases" do
    expect(Igniter::Ledger::LedgerServer).to eq(Igniter::Store::StoreServer)
    expect(Igniter::Store::LedgerServer).to eq(Igniter::Store::StoreServer)
    expect(Igniter::Ledger::LedgerNetworkBackend).to eq(Igniter::Store::NetworkBackend)
    expect(Igniter::Store::LedgerNetworkBackend).to eq(Igniter::Store::NetworkBackend)
  end

  it "prints the new executable version without starting a server" do
    stdout, stderr, status = run_ruby(File.join(EXE_DIR, "igniter-ledger-server"), "--version")

    expect_success(stdout, stderr, status)
    expect(stdout).to match(/\Aigniter-ledger \S+/)
    expect(stderr).to eq("")
  end

  it "prints the old executable version and deprecation warning without starting a server" do
    stdout, stderr, status = run_ruby(File.join(EXE_DIR, "igniter-store-server"), "--version")

    expect_success(stdout, stderr, status)
    expect(stdout).to match(/\Aigniter-ledger \S+/)
    expect(stderr).to include("igniter-store-server is deprecated; use igniter-ledger-server instead")
  end
end
