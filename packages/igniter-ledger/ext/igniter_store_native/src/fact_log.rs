use magnus::{prelude::*, Error, IntoValue, RArray, RHash, Ruby, Value};
use parking_lot::RwLock;
use std::collections::HashMap;

use crate::fact::{ruby_hash_to_json_sorted, Fact, FactData};

struct FactLogInner {
    log: Vec<FactData>,
    by_id: HashMap<String, usize>,
    /// (store, key) → insertion-ordered indices into `log`
    by_key: HashMap<(String, String), Vec<usize>>,
}

impl FactLogInner {
    fn push(&mut self, data: FactData) {
        let idx = self.log.len();
        self.by_id.insert(data.id.clone(), idx);
        self.by_key
            .entry((data.store.clone(), data.key.clone()))
            .or_default()
            .push(idx);
        self.log.push(data);
    }
}

#[magnus::wrap(class = "Igniter::Store::FactLog", free_immediately, size)]
pub struct FactLog(RwLock<FactLogInner>);

impl FactLog {
    pub fn rb_new() -> Self {
        FactLog(RwLock::new(FactLogInner {
            log: Vec::new(),
            by_id: HashMap::new(),
            by_key: HashMap::new(),
        }))
    }

    /// Appends a fact. Returns nil; Ruby wrapper returns the original Fact arg.
    pub fn rb_append(&self, rb_fact: &Fact) -> Value {
        self.0.write().push(rb_fact.0.clone());
        let ruby = unsafe { Ruby::get_unchecked() };
        ruby.qnil().as_value()
    }

    /// Replays a fact during WAL restore (no backend write).
    pub fn rb_replay_fact(&self, rb_fact: &Fact) {
        self.0.write().push(rb_fact.0.clone());
    }

    pub fn rb_latest_for_native(
        &self,
        store: String,
        key: String,
        as_of: Option<f64>,
    ) -> Value {
        let ruby = unsafe { Ruby::get_unchecked() };
        let inner = self.0.read();
        let k = (store, key);
        let indices = match inner.by_key.get(&k) {
            Some(v) => v,
            None => return ruby.qnil().as_value(),
        };

        let latest_idx = if let Some(as_of) = as_of {
            indices
                .iter()
                .rev()
                .find(|&&i| inner.log[i].transaction_time <= as_of)
                .copied()
        } else {
            indices.last().copied()
        };

        match latest_idx {
            Some(idx) => {
                let data = inner.log[idx].clone();
                drop(inner);
                Fact(data).into_value_with(&ruby)
            }
            None => ruby.qnil().as_value(),
        }
    }

    pub fn rb_facts_for_native(
        &self,
        store: String,
        key: Option<String>,
        since: Option<f64>,
        as_of: Option<f64>,
    ) -> Result<RArray, Error> {
        let ruby = unsafe { Ruby::get_unchecked() };
        let inner = self.0.read();

        let indices: Vec<usize> = if let Some(ref k) = key {
            inner
                .by_key
                .get(&(store.clone(), k.clone()))
                .cloned()
                .unwrap_or_default()
        } else {
            (0..inner.log.len())
                .filter(|&i| inner.log[i].store == store)
                .collect()
        };

        let filtered: Vec<FactData> = indices
            .into_iter()
            .filter(|&i| {
                let t = inner.log[i].transaction_time;
                since.map_or(true, |s| t >= s) && as_of.map_or(true, |a| t <= a)
            })
            .map(|i| inner.log[i].clone())
            .collect();

        drop(inner);

        let arr = RArray::new();
        for data in filtered {
            arr.push(Fact(data).into_value_with(&ruby))?;
        }
        Ok(arr)
    }

    pub fn rb_size(&self) -> usize {
        self.0.read().log.len()
    }

    /// Returns latest fact per key in `store` whose `value` matches all `filters`.
    /// `filters` is a Ruby Hash like `{ status: :pending }`.
    /// Returns the latest fact per key (optionally as of a timestamp).
    pub fn rb_query_scope_native(
        &self,
        store: String,
        filters: RHash,
        as_of: Option<f64>,
    ) -> Result<RArray, Error> {
        let ruby = unsafe { Ruby::get_unchecked() };
        let filter_json = ruby_hash_to_json_sorted(filters.as_value());

        let inner = self.0.read();

        let mut results: Vec<FactData> = Vec::new();

        for ((s, _k), indices) in &inner.by_key {
            if s != &store {
                continue;
            }
            let latest_idx = if let Some(as_of) = as_of {
                indices
                    .iter()
                    .rev()
                    .find(|&&i| inner.log[i].transaction_time <= as_of)
                    .copied()
            } else {
                indices.last().copied()
            };
            if let Some(idx) = latest_idx {
                if matches_filters(&inner.log[idx].value, &filter_json) {
                    results.push(inner.log[idx].clone());
                }
            }
        }
        drop(inner);

        let arr = RArray::new();
        for data in results {
            arr.push(Fact(data).into_value_with(&ruby))?;
        }
        Ok(arr)
    }
}

fn matches_filters(value: &serde_json::Value, filters: &serde_json::Value) -> bool {
    match (value, filters) {
        (serde_json::Value::Object(v), serde_json::Value::Object(f)) => {
            f.iter().all(|(k, fv)| v.get(k).map_or(false, |vv| vv == fv))
        }
        _ => false,
    }
}
