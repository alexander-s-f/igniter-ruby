mod fact;
mod fact_log;
mod file_backend;

use magnus::{function, method, prelude::*, Error, Module, Ruby};

use fact::Fact;
use fact_log::FactLog;
use file_backend::FileBackend;

#[magnus::init]
fn init(ruby: &Ruby) -> Result<(), Error> {
    let igniter = ruby.define_module("Igniter")?;
    let store_mod = igniter.define_module("Store")?;

    // ── Fact ──────────────────────────────────────────────────────────────────
    let fact_class = store_mod.define_class("Fact", ruby.class_object())?;
    fact_class.define_singleton_method("_native_build", function!(fact::rb_build, 8))?;
    fact_class.define_method("id",               method!(Fact::rb_id, 0))?;
    fact_class.define_method("store",            method!(Fact::rb_store, 0))?;
    fact_class.define_method("key",              method!(Fact::rb_key, 0))?;
    fact_class.define_method("value",            method!(Fact::rb_value, 0))?;
    fact_class.define_method("value_hash",       method!(Fact::rb_value_hash, 0))?;
    fact_class.define_method("causation",        method!(Fact::rb_causation, 0))?;
    fact_class.define_method("transaction_time", method!(Fact::rb_transaction_time, 0))?;
    fact_class.define_method("valid_time",       method!(Fact::rb_valid_time, 0))?;
    fact_class.define_method("producer",         method!(Fact::rb_producer, 0))?;
    fact_class.define_method("derivation",       method!(Fact::rb_derivation, 0))?;
    fact_class.define_method("schema_version",   method!(Fact::rb_schema_version, 0))?;
    fact_class.define_method("to_h",             method!(Fact::rb_to_h, 0))?;
    fact_class.define_method("inspect",          method!(Fact::rb_inspect, 0))?;
    fact_class.define_method("frozen?",          method!(Fact::rb_frozen, 0))?;
    // Backward-compat aliases (removed after callers migrate)
    fact_class.define_method("timestamp",        method!(Fact::rb_timestamp, 0))?;
    fact_class.define_method("term",             method!(Fact::rb_term, 0))?;

    // ── FactLog ───────────────────────────────────────────────────────────────
    let log_class = store_mod.define_class("FactLog", ruby.class_object())?;
    log_class.define_singleton_method("new", function!(FactLog::rb_new, 0))?;
    log_class.define_method("_native_append",      method!(FactLog::rb_append, 1))?;
    log_class.define_method("replay",              method!(FactLog::rb_replay_fact, 1))?;
    log_class.define_method("latest_for_native",   method!(FactLog::rb_latest_for_native, 3))?;
    log_class.define_method("facts_for_native",       method!(FactLog::rb_facts_for_native, 4))?;
    log_class.define_method("query_scope_native",     method!(FactLog::rb_query_scope_native, 3))?;
    log_class.define_method("size",                   method!(FactLog::rb_size, 0))?;

    // ── FileBackend ───────────────────────────────────────────────────────────
    let fb_class = store_mod.define_class("FileBackend", ruby.class_object())?;
    fb_class.define_singleton_method("new",   function!(FileBackend::rb_new, 1))?;
    fb_class.define_method("write_fact",      method!(FileBackend::rb_write_fact, 1))?;
    fb_class.define_method("replay",          method!(FileBackend::rb_replay, 0))?;
    fb_class.define_method("close",           method!(FileBackend::rb_close, 0))?;

    Ok(())
}
