use magnus::{
    r_hash::ForEach, prelude::*, Error, Float as RbFloat, IntoValue, Integer as RbInteger,
    RArray, RHash, Ruby, Symbol, Value,
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// Pure-Rust representation of an immutable fact.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FactData {
    pub id: String,
    pub store: String,
    pub key: String,
    /// Stable-sorted JSON with symbol-tagged strings (":foo" = Ruby :foo).
    pub value: serde_json::Value,
    pub value_hash: String,
    pub causation: Option<String>,
    /// Wall-clock epoch seconds when the fact was committed (auto-set by store).
    pub transaction_time: f64,
    /// Domain time: when the event is asserted to be true in the world (writer-supplied, nullable).
    pub valid_time: Option<f64>,
    pub schema_version: i64,
    /// Typed producer reference: { type:, name:, ... } or nil.
    pub producer: Option<serde_json::Value>,
    /// Inline provenance for derived facts: { name:, version:, source_fact_ids:, ... } or nil.
    pub derivation: Option<serde_json::Value>,
}

/// Ruby-visible Fact class backed by Rust.
#[magnus::wrap(class = "Igniter::Store::Fact", free_immediately, size)]
pub struct Fact(pub FactData);

// ── Class method ─────────────────────────────────────────────────────────────

/// Build a Fact from Ruby arguments (8-arg form used by native.rb build wrapper).
/// valid_time and schema_version are positional; producer and derivation are Value
/// so they can accept Ruby nil without a wrapper type.
pub fn rb_build(
    store: String,
    key: String,
    rb_value: RHash,
    causation: Option<String>,
    valid_time_val: Value,
    schema_version: i64,
    producer_val: Value,
    derivation_val: Value,
) -> Result<Fact, Error> {
    let json_val = ruby_hash_to_json_sorted(rb_value.as_value());
    let json_str = serde_json::to_string(&json_val)
        .map_err(|e| Error::new(magnus::exception::runtime_error(), e.to_string()))?;
    let value_hash = blake3::hash(json_str.as_bytes()).to_hex().to_string();

    let valid_time = if valid_time_val.is_nil() {
        None
    } else {
        RbFloat::from_value(valid_time_val)
            .map(|f| Some(f.to_f64()))
            .unwrap_or_else(|| {
                RbInteger::from_value(valid_time_val)
                    .and_then(|i| i.to_i64().ok())
                    .map(|i| i as f64)
            })
    };

    let producer = if producer_val.is_nil() {
        None
    } else {
        Some(ruby_hash_to_json_sorted(producer_val))
    };

    let derivation = if derivation_val.is_nil() {
        None
    } else {
        Some(ruby_hash_to_json_sorted(derivation_val))
    };

    Ok(Fact(FactData {
        id: uuid::Uuid::new_v4().to_string(),
        store,
        key,
        value: json_val,
        value_hash,
        causation,
        transaction_time: current_time(),
        valid_time,
        schema_version,
        producer,
        derivation,
    }))
}

// ── Instance methods ──────────────────────────────────────────────────────────

impl Fact {
    pub fn rb_id(&self) -> String { self.0.id.clone() }
    pub fn rb_store(&self) -> String { self.0.store.clone() }
    pub fn rb_key(&self) -> String { self.0.key.clone() }

    pub fn rb_value(&self) -> Value {
        let ruby = unsafe { Ruby::get_unchecked() };
        json_to_ruby_value(&ruby, &self.0.value)
    }

    pub fn rb_value_hash(&self) -> String { self.0.value_hash.clone() }

    pub fn rb_causation(&self) -> Value {
        let ruby = unsafe { Ruby::get_unchecked() };
        match &self.0.causation {
            Some(s) => s.as_str().into_value_with(&ruby),
            None    => ruby.qnil().as_value(),
        }
    }

    /// Canonical name for when the fact was committed.
    pub fn rb_transaction_time(&self) -> f64 { self.0.transaction_time }

    /// Canonical name for the domain valid time (nullable).
    pub fn rb_valid_time(&self) -> Value {
        let ruby = unsafe { Ruby::get_unchecked() };
        match self.0.valid_time {
            Some(v) => v.into_value_with(&ruby),
            None    => ruby.qnil().as_value(),
        }
    }

    /// Backward-compat alias for transaction_time.
    pub fn rb_timestamp(&self) -> f64 { self.0.transaction_time }

    /// Backward-compat alias for valid_time (returns 0 when nil, matching old term: 0 default).
    pub fn rb_term(&self) -> f64 { self.0.valid_time.unwrap_or(0.0) }

    pub fn rb_schema_version(&self) -> i64 { self.0.schema_version }

    pub fn rb_producer(&self) -> Value {
        let ruby = unsafe { Ruby::get_unchecked() };
        match &self.0.producer {
            Some(v) => json_to_ruby_value(&ruby, v),
            None    => ruby.qnil().as_value(),
        }
    }

    pub fn rb_derivation(&self) -> Value {
        let ruby = unsafe { Ruby::get_unchecked() };
        match &self.0.derivation {
            Some(v) => json_to_ruby_value(&ruby, v),
            None    => ruby.qnil().as_value(),
        }
    }

    pub fn rb_frozen(&self) -> bool { true }

    pub fn rb_to_h(&self) -> Result<RHash, Error> {
        let ruby = unsafe { Ruby::get_unchecked() };
        let h = RHash::new();
        h.aset(Symbol::new("id"),               self.0.id.as_str())?;
        h.aset(Symbol::new("store"),            Symbol::new(self.0.store.as_str()))?;
        h.aset(Symbol::new("key"),              self.0.key.as_str())?;
        h.aset(Symbol::new("value"),            json_to_ruby_value(&ruby, &self.0.value))?;
        h.aset(Symbol::new("value_hash"),       self.0.value_hash.as_str())?;
        match &self.0.causation {
            Some(s) => h.aset(Symbol::new("causation"), s.as_str())?,
            None    => h.aset(Symbol::new("causation"), ruby.qnil())?,
        }
        h.aset(Symbol::new("transaction_time"), self.0.transaction_time)?;
        match self.0.valid_time {
            Some(v) => h.aset(Symbol::new("valid_time"), v)?,
            None    => h.aset(Symbol::new("valid_time"), ruby.qnil())?,
        }
        h.aset(Symbol::new("schema_version"),   self.0.schema_version)?;
        match &self.0.producer {
            Some(v) => h.aset(Symbol::new("producer"), json_to_ruby_value(&ruby, v))?,
            None    => h.aset(Symbol::new("producer"), ruby.qnil())?,
        }
        match &self.0.derivation {
            Some(v) => h.aset(Symbol::new("derivation"), json_to_ruby_value(&ruby, v))?,
            None    => h.aset(Symbol::new("derivation"), ruby.qnil())?,
        }
        Ok(h)
    }

    pub fn rb_inspect(&self) -> String {
        format!(
            "#<Igniter::Store::Fact store={:?} key={:?} hash={}>",
            self.0.store,
            self.0.key,
            &self.0.value_hash[..12]
        )
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

pub fn ruby_hash_to_json_sorted(val: Value) -> serde_json::Value {
    ruby_to_json_inner(val)
}

fn ruby_to_json_inner(val: Value) -> serde_json::Value {
    if val.is_nil() {
        return serde_json::Value::Null;
    }
    // Symbol :foo → tagged string ":foo" (preserves round-trip identity)
    if let Some(sym) = Symbol::from_value(val) {
        let name = sym.name().unwrap_or_default();
        return serde_json::Value::String(format!(":{name}"));
    }
    // Array
    if let Some(arr) = RArray::from_value(val) {
        let len = arr.len();
        let items: Vec<serde_json::Value> = (0..len)
            .map(|i| {
                arr.entry(i as isize)
                    .map(ruby_to_json_inner)
                    .unwrap_or(serde_json::Value::Null)
            })
            .collect();
        return serde_json::Value::Array(items);
    }
    // Hash — keys sorted via BTreeMap for stable hashing
    if let Some(hash) = RHash::from_value(val) {
        let mut map: BTreeMap<String, serde_json::Value> = BTreeMap::new();
        let _ = hash.foreach(|k: Value, v: Value| {
            let key = if let Some(sym) = Symbol::from_value(k) {
                sym.name().unwrap_or_default().to_string()
            } else if let Ok(s) = String::try_convert(k) {
                s
            } else {
                k.inspect()
            };
            map.insert(key, ruby_to_json_inner(v));
            Ok(ForEach::Continue)
        });
        return serde_json::Value::Object(map.into_iter().collect());
    }
    // Integer — exact Ruby type check to avoid coercing Float 7.0 → 7
    if let Some(int) = RbInteger::from_value(val) {
        if let Ok(n) = int.to_i64() {
            return serde_json::json!(n);
        }
    }
    // Float — exact Ruby type check
    if let Some(flt) = RbFloat::from_value(val) {
        return serde_json::json!(flt.to_f64());
    }
    // String
    if let Ok(s) = String::try_convert(val) {
        return serde_json::Value::String(s);
    }
    // Boolean fallback via inspect
    match val.inspect().as_str() {
        "true"  => serde_json::Value::Bool(true),
        "false" => serde_json::Value::Bool(false),
        other   => serde_json::Value::String(other.to_string()),
    }
}

/// serde_json::Value → Ruby Value.
/// Strings prefixed with ":" are restored as Ruby Symbols.
pub fn json_to_ruby_value(ruby: &Ruby, val: &serde_json::Value) -> Value {
    match val {
        serde_json::Value::Null => ruby.qnil().as_value(),
        serde_json::Value::Bool(b) => {
            if *b { ruby.qtrue().as_value() } else { ruby.qfalse().as_value() }
        }
        serde_json::Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                i.into_value_with(ruby)
            } else if let Some(f) = n.as_f64() {
                f.into_value_with(ruby)
            } else {
                ruby.qnil().as_value()
            }
        }
        serde_json::Value::String(s) => {
            if s.starts_with(':') {
                Symbol::new(&s[1..]).as_value()
            } else {
                s.as_str().into_value_with(ruby)
            }
        }
        serde_json::Value::Array(arr) => {
            let rb_arr = RArray::new();
            for item in arr {
                let _ = rb_arr.push(json_to_ruby_value(ruby, item));
            }
            rb_arr.as_value()
        }
        serde_json::Value::Object(obj) => {
            let rb_hash = RHash::new();
            for (k, v) in obj {
                let key = Symbol::new(k.as_str()).as_value();
                let _ = rb_hash.aset(key, json_to_ruby_value(ruby, v));
            }
            rb_hash.as_value()
        }
    }
}

fn current_time() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}
