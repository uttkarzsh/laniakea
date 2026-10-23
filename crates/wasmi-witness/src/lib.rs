//! Portable Circom 2 witness generation on top of the Wasmi interpreter.
//!
//! A Circom-generated `.wasm` is a *witness calculator*. It does not expose
//! the witness as plain memory; it exposes a small function interface and a
//! "shared read/write memory" (RW memory) window of `n32` 32-bit limbs through
//! which every field element crosses the host/WASM boundary:
//!
//! ```text
//! host -> wasm   writeSharedRWMemory(j, limb_j) for j in 0..n32;  setInputSignal(hash_hi, hash_lo, i)
//! wasm -> host   getWitness(i);  readSharedRWMemory(j) for j in 0..n32
//! ```
//!
//! Limbs are little-endian: limb 0 is the least significant 32 bits. Nothing
//! here depends on where the module places its internal data, so the code is
//! not tied to a particular circuit. The reference behaviour is the
//! `witness_calculator.js` that `circom --wasm` emits next to each module.

use ark_bn254::Fr;
use ark_ff::PrimeField;
use num_bigint::{BigInt, BigUint};
use num_traits::Signed;
use std::collections::HashSet;
use thiserror::Error;
use wasmi::{Caller, Engine, Instance, Linker, Module, Store, TypedFunc, WasmParams, WasmResults};

/// Upper bound on a single Circom error/log message, to bound a misbehaving module.
const MAX_MESSAGE_LEN: usize = 64 * 1024;

#[derive(Debug, Error)]
pub enum WasmiWitnessError {
    #[error("WASM module error: {0}")]
    Module(String),

    #[error("WASM instantiation error: {0}")]
    Instantiation(String),

    #[error("WASM execution error: {0}")]
    Execution(String),

    #[error("Memory read error: {0}")]
    MemoryRead(String),

    #[error("Witness generation error: {0}")]
    WitnessGeneration(String),

    /// The circuit's field is not the BN254 scalar field this crate targets.
    #[error("unsupported field: {0}")]
    UnsupportedField(String),

    /// The circuit itself aborted witness generation (failed `assert` or `===`,
    /// array access out of range, ...). `code` is Circom's exception code and
    /// `detail` is the template trace the module reported, if any.
    #[error("circuit execution failed: {reason} (code {code}){}", fmt_detail(.detail))]
    Circom {
        code: i32,
        reason: &'static str,
        detail: String,
    },

    /// An input name the circuit does not declare, detected on the host side.
    ///
    /// This is an early check built on `getInputSignalSize`, which is only a
    /// hint: for an unknown name the generated module's lookup finds nothing
    /// and the size comes back 0 (in the modules inspected), the same value a
    /// genuine zero-length array reports. A name with an empty value list is
    /// therefore indistinguishable from a zero-length array and is accepted.
    /// Conversely, values supplied for a *declared* zero-length input also
    /// report size 0 and so produce this variant, although the name is known.
    /// The definitive check lives in the module's `setInputSignal`, which
    /// raises exception code 1 ("signal not found"); that case is propagated
    /// as [`WasmiWitnessError::Circom`] with `code: 1`, not as this variant.
    #[error("unknown input signal `{0}`")]
    UnknownSignal(String),

    /// The wrong number of values was given for an input signal (array length).
    #[error("input signal `{signal}` expects {expected} value(s), got {got}")]
    InputSize {
        signal: String,
        expected: usize,
        got: usize,
    },

    /// The same input name appeared more than once in the input list.
    #[error("input signal `{0}` was provided more than once")]
    DuplicateSignal(String),

    /// Not every input value the circuit declares was assigned.
    #[error("not all inputs were set: {set} of {expected} values provided")]
    MissingInputs { set: usize, expected: usize },
}

fn fmt_detail(detail: &str) -> String {
    if detail.is_empty() {
        String::new()
    } else {
        format!(": {}", detail.trim_end().replace('\n', "; "))
    }
}

/// Host-side state shared with the imported `runtime.*` functions.
#[derive(Default)]
struct HostState {
    /// Set by `exceptionHandler`; consumed when the resulting trap surfaces.
    exception: Option<i32>,
    /// Accumulated by `printErrorMessage` (template trace for the exception).
    error_message: String,
    /// Test builds only: counts live stores (see `live_stores`).
    #[cfg(test)]
    _live: LiveStoreGuard,
}

// Test-only lifecycle tracking. Every `Store` owns a `HostState`, so counting
// `HostState`s that are alive counts stores that have not been dropped. The
// count is per thread, so parallel tests cannot disturb each other. Compiled
// out of non-test builds entirely.
#[cfg(test)]
thread_local! {
    static LIVE_STORES: std::cell::Cell<isize> = const { std::cell::Cell::new(0) };
}

#[cfg(test)]
struct LiveStoreGuard;

#[cfg(test)]
impl Default for LiveStoreGuard {
    fn default() -> Self {
        LIVE_STORES.with(|n| n.set(n.get() + 1));
        LiveStoreGuard
    }
}

#[cfg(test)]
impl Drop for LiveStoreGuard {
    fn drop(&mut self) {
        let _ = LIVE_STORES.try_with(|n| n.set(n.get() - 1));
    }
}

/// A Circom witness calculator backed by a compiled WASM module.
///
/// The calculator keeps no per-run WASM state: only the [`Engine`], the compiled
/// [`Module`], the [`Linker`] holding the host imports, and constants read from
/// the module in [`Self::new`]. Every [`Self::calculate_witness`] call
/// instantiates the module into its own [`Store`], so no WASM memory, stack or
/// host-side error state outlives a call.
pub struct WasmiWitnessCalculator {
    engine: Engine,
    module: Module,
    linker: Linker<HostState>,
    n32: usize,
    prime: BigInt,
    input_size: usize,
    witness_size: usize,
}

impl WasmiWitnessCalculator {
    pub fn new(wasm_bytes: &[u8]) -> Result<Self, WasmiWitnessError> {
        let engine = Engine::default();

        let module = Module::new(&engine, &mut &wasm_bytes[..])
            .map_err(|e| WasmiWitnessError::Module(e.to_string()))?;

        let mut linker = Linker::new(&engine);
        define_runtime_imports(&mut linker)?;

        // This instance only exists to read the module's constants; it is
        // dropped before `new` returns. Witness runs use their own instances.
        let (mut store, instance) = instantiate(&engine, &module, &linker)?;

        let get_field_num_len32 = typed::<(), i32>(&instance, &store, "getFieldNumLen32")?;
        let n32 = call(&get_field_num_len32, &mut store, (), "getFieldNumLen32")?;
        if n32 <= 0 {
            return Err(WasmiWitnessError::UnsupportedField(format!(
                "getFieldNumLen32 returned {n32}"
            )));
        }
        let n32 = n32 as usize;

        // The prime is delivered through the shared RW memory like any other
        // field element: getRawPrime() fills it, readSharedRWMemory(j) reads it.
        let get_raw_prime = typed::<(), ()>(&instance, &store, "getRawPrime")?;
        call(&get_raw_prime, &mut store, (), "getRawPrime")?;
        let read_rw = typed::<i32, i32>(&instance, &store, "readSharedRWMemory")?;
        let prime = BigInt::from(read_field_element(&read_rw, &mut store, n32)?);

        let expected_prime = BigInt::from(BigUint::from(Fr::MODULUS));
        if prime != expected_prime {
            return Err(WasmiWitnessError::UnsupportedField(format!(
                "circuit prime {prime} is not the BN254 scalar field modulus"
            )));
        }

        let get_input_size = typed::<(), i32>(&instance, &store, "getInputSize")?;
        let input_size = call(&get_input_size, &mut store, (), "getInputSize")?;
        let get_witness_size = typed::<(), i32>(&instance, &store, "getWitnessSize")?;
        let witness_size = call(&get_witness_size, &mut store, (), "getWitnessSize")?;
        if input_size < 0 || witness_size < 0 {
            return Err(WasmiWitnessError::Instantiation(format!(
                "negative size from module: getInputSize={input_size}, getWitnessSize={witness_size}"
            )));
        }

        Ok(Self {
            engine,
            module,
            linker,
            n32,
            prime,
            input_size: input_size as usize,
            witness_size: witness_size as usize,
        })
    }

    /// Calculate the full witness `[1, outputs..., public inputs..., private inputs..., intermediates...]`.
    ///
    /// Each input is `(signal name, values)`; arrays are passed flattened in
    /// row-major order under the array's name (`"v"`, not `"v[0]"`). Values are
    /// reduced modulo the field prime (negative values wrap to `p - |x|`),
    /// exactly as Circom's JS calculator does.
    ///
    /// Fails if a name is unknown or repeated, if an array length is wrong, if
    /// any declared input is left unset, or if the circuit aborts (failed
    /// `assert` / `===`). A witness is returned only if every step succeeded.
    ///
    /// # Lifecycle
    ///
    /// Each call creates a fresh [`Store`] and WASM instance from the module
    /// compiled in [`Self::new`], runs on it, and drops it, whether the run
    /// succeeded or failed. Linear memory, the module's internal stack and the
    /// host-side error state are therefore never carried from one call to the
    /// next; a trap or aborted run cannot affect a later call. The cost is one
    /// instantiation per call, which allocates and zero-fills the module's
    /// initial linear memory (704 KiB for the circuits in this repository).
    ///
    /// The [`Engine`], [`Module`] and [`Linker`] (plus constants read in `new`)
    /// are shared between calls. Runs never write to the module's data, but
    /// the engine is not strictly read-only: Wasmi translates each function
    /// lazily the first time it executes and caches the result in the shared
    /// engine. That cache affects speed only, not results.
    pub fn calculate_witness(
        &mut self,
        inputs: &[(String, Vec<BigInt>)],
    ) -> Result<Vec<Fr>, WasmiWitnessError> {
        self.run_fresh(inputs).0
    }

    /// Instantiate the module and run once on that instance. Also returns the
    /// instance's final linear-memory size in bytes (0 if it was never
    /// instantiated), which the tests use to check that runs leave nothing behind.
    fn run_fresh(
        &self,
        inputs: &[(String, Vec<BigInt>)],
    ) -> (Result<Vec<Fr>, WasmiWitnessError>, usize) {
        let (mut store, instance) = match instantiate(&self.engine, &self.module, &self.linker) {
            Ok(pair) => pair,
            Err(e) => return (Err(e), 0),
        };
        let result = self.run_in(&mut store, &instance, inputs);
        let memory_bytes = linear_memory_bytes(&store, &instance);
        (result, memory_bytes)
    }

    /// Run one witness calculation on `instance`.
    ///
    /// The instance must be fresh: `init` is called, but a previous run that
    /// aborted may have left the module's stack pointer advanced, and `init`
    /// does not restore it.
    fn run_in(
        &self,
        store: &mut Store<HostState>,
        instance: &Instance,
        inputs: &[(String, Vec<BigInt>)],
    ) -> Result<Vec<Fr>, WasmiWitnessError> {
        let mut seen = HashSet::new();
        for (name, _) in inputs {
            if !seen.insert(name.as_str()) {
                return Err(WasmiWitnessError::DuplicateSignal(name.clone()));
            }
        }

        let init = typed::<i32, ()>(instance, store, "init")?;
        let get_input_signal_size =
            typed::<(i32, i32), i32>(instance, store, "getInputSignalSize")?;
        let write_rw = typed::<(i32, i32), ()>(instance, store, "writeSharedRWMemory")?;
        let set_input_signal = typed::<(i32, i32, i32), ()>(instance, store, "setInputSignal")?;
        let read_rw = typed::<i32, i32>(instance, store, "readSharedRWMemory")?;
        let get_witness = typed::<i32, ()>(instance, store, "getWitness")?;

        // `1` enables the module's own sanity checks (same as the JS calculator).
        call(&init, store, 1, "init")?;

        let mut set_count = 0usize;

        for (name, values) in inputs {
            let (msb, lsb) = fnv(name);
            let (msb, lsb) = (msb as i32, lsb as i32);

            // getInputSignalSize is only a hint, not an existence check. For a
            // name the module does not know, its lookup yields no entry and the
            // size read comes back 0 in the modules we have inspected; a
            // genuinely zero-length array reports 0 too. So 0 with values to
            // assign is treated as unknown here, which gives a clear error
            // early. The definitive check is inside the module: setInputSignal
            // raises exception code 1 ("signal not found"), which `call`
            // propagates as `Circom { code: 1, .. }`.
            let signal_size = call(
                &get_input_signal_size,
                store,
                (msb, lsb),
                "getInputSignalSize",
            )?;
            if signal_size < 0 || (signal_size == 0 && !values.is_empty()) {
                return Err(WasmiWitnessError::UnknownSignal(name.clone()));
            }
            let signal_size = signal_size as usize;
            if values.len() != signal_size {
                return Err(WasmiWitnessError::InputSize {
                    signal: name.clone(),
                    expected: signal_size,
                    got: values.len(),
                });
            }

            for (index, value) in values.iter().enumerate() {
                let limbs = field_to_limbs(value, &self.prime, self.n32);
                for (j, limb) in limbs.iter().enumerate() {
                    call(
                        &write_rw,
                        store,
                        (j as i32, *limb as i32),
                        "writeSharedRWMemory",
                    )?;
                }
                call(
                    &set_input_signal,
                    store,
                    (msb, lsb, index as i32),
                    "setInputSignal",
                )?;
                set_count += 1;
            }
        }

        if set_count < self.input_size {
            return Err(WasmiWitnessError::MissingInputs {
                set: set_count,
                expected: self.input_size,
            });
        }

        let mut witness = Vec::with_capacity(self.witness_size);
        for i in 0..self.witness_size {
            call(&get_witness, store, i as i32, "getWitness")?;
            let value = read_field_element(&read_rw, store, self.n32)?;
            if BigInt::from(value.clone()) >= self.prime {
                return Err(WasmiWitnessError::WitnessGeneration(format!(
                    "witness[{i}] is not a canonical field element"
                )));
            }
            witness.push(Fr::from_le_bytes_mod_order(&value.to_bytes_le()));
        }

        Ok(witness)
    }

    /// Total number of scalar input values the circuit expects
    /// (`getInputSize`): every element of every input signal, public or private.
    /// This is **not** the number of public witness entries.
    pub fn num_public(&self) -> usize {
        self.input_size
    }

    /// Same value as [`Self::num_public`], under its accurate name.
    pub fn input_size(&self) -> usize {
        self.input_size
    }

    /// Number of elements `calculate_witness` returns (`getWitnessSize`).
    /// This equals the R1CS header's wire count, constant `1` included.
    pub fn witness_size(&self) -> usize {
        self.witness_size
    }

    pub fn prime(&self) -> &BigInt {
        &self.prime
    }
}

/// Create a new store and an instance of `module` in it. Each store owns its
/// own linear memory, tables and [`HostState`].
fn instantiate(
    engine: &Engine,
    module: &Module,
    linker: &Linker<HostState>,
) -> Result<(Store<HostState>, Instance), WasmiWitnessError> {
    let mut store = Store::new(engine, HostState::default());
    let instance = linker
        .instantiate_and_start(&mut store, module)
        .map_err(|e| WasmiWitnessError::Instantiation(e.to_string()))?;
    Ok((store, instance))
}

fn linear_memory_bytes(store: &Store<HostState>, instance: &Instance) -> usize {
    instance
        .get_memory(store, "memory")
        .map_or(0, |memory| memory.data(store).len())
}

/* -------------------------------------------------------------------------- */
/* Host imports                                                               */
/* -------------------------------------------------------------------------- */

/// Circom 2 modules import five functions from the `runtime` namespace.
///
/// `exceptionHandler(code)` is how a circuit aborts (a failed `assert` or `===`
/// ends up here). It must not return normally: the JS calculator throws, and
/// here we return an `Err` so Wasmi traps and unwinds out of the module.
fn define_runtime_imports(linker: &mut Linker<HostState>) -> Result<(), WasmiWitnessError> {
    let inst = |e: wasmi::errors::LinkerError| WasmiWitnessError::Instantiation(e.to_string());

    linker
        .func_wrap(
            "runtime",
            "exceptionHandler",
            |mut caller: Caller<'_, HostState>, code: i32| -> Result<(), wasmi::Error> {
                caller.data_mut().exception = Some(code);
                Err(wasmi::Error::new("circom exception"))
            },
        )
        .map_err(inst)?;

    // The module has already placed a message in its own buffer; pull it out
    // with getMessageChar() (NUL-terminated) and keep it for the error report.
    linker
        .func_wrap(
            "runtime",
            "printErrorMessage",
            |mut caller: Caller<'_, HostState>| {
                let message = drain_message(&mut caller);
                let state = caller.data_mut();
                state.error_message.push_str(&message);
                state.error_message.push('\n');
            },
        )
        .map_err(inst)?;

    // `log()` output. Drained so the module's buffer advances, then discarded.
    linker
        .func_wrap(
            "runtime",
            "writeBufferMessage",
            |mut caller: Caller<'_, HostState>| {
                let _ = drain_message(&mut caller);
            },
        )
        .map_err(inst)?;

    linker
        .func_wrap(
            "runtime",
            "showSharedRWMemory",
            |_caller: Caller<'_, HostState>| {},
        )
        .map_err(inst)?;

    Ok(())
}

fn drain_message(caller: &mut Caller<'_, HostState>) -> String {
    let Some(func) = caller
        .get_export("getMessageChar")
        .and_then(|export| export.into_func())
    else {
        return String::new();
    };
    let Ok(get_char) = func.typed::<(), i32>(&*caller) else {
        return String::new();
    };

    let mut message = String::new();
    while message.len() < MAX_MESSAGE_LEN {
        match get_char.call(&mut *caller, ()) {
            Ok(0) | Err(_) => break,
            Ok(c) => message.push(char::from_u32(c as u32).unwrap_or('?')),
        }
    }
    message
}

/* -------------------------------------------------------------------------- */
/* Calling into the module                                                    */
/* -------------------------------------------------------------------------- */

fn typed<P: WasmParams, R: WasmResults>(
    instance: &Instance,
    store: &Store<HostState>,
    name: &str,
) -> Result<TypedFunc<P, R>, WasmiWitnessError> {
    instance
        .get_typed_func::<P, R>(store, name)
        .map_err(|e| WasmiWitnessError::Instantiation(format!("export `{name}`: {e}")))
}

/// Call an export, turning a trap caused by `exceptionHandler` into a
/// [`WasmiWitnessError::Circom`] and any other trap into `Execution`.
fn call<P: WasmParams, R: WasmResults>(
    func: &TypedFunc<P, R>,
    store: &mut Store<HostState>,
    params: P,
    what: &str,
) -> Result<R, WasmiWitnessError> {
    func.call(&mut *store, params).map_err(|e| {
        let state = store.data_mut();
        match state.exception.take() {
            Some(code) => WasmiWitnessError::Circom {
                code,
                reason: exception_reason(code),
                detail: std::mem::take(&mut state.error_message),
            },
            None => WasmiWitnessError::Execution(format!("{what} failed: {e}")),
        }
    })
}

/// Same codes as the JS calculator's `exceptionHandler`.
fn exception_reason(code: i32) -> &'static str {
    match code {
        1 => "signal not found",
        2 => "too many signals set",
        3 => "signal already set",
        4 => "assert failed",
        5 => "not enough memory",
        6 => "input signal array access exceeds the size",
        _ => "unknown error",
    }
}

/* -------------------------------------------------------------------------- */
/* Field element <-> shared RW memory                                         */
/* -------------------------------------------------------------------------- */

/// Read one field element from the shared RW memory: `n32` little-endian limbs.
fn read_field_element(
    read_rw: &TypedFunc<i32, i32>,
    store: &mut Store<HostState>,
    n32: usize,
) -> Result<BigUint, WasmiWitnessError> {
    let mut limbs = Vec::with_capacity(n32);
    for j in 0..n32 {
        let limb = call(read_rw, store, j as i32, "readSharedRWMemory")?;
        limbs.push(limb as u32);
    }
    Ok(u32_limbs_to_biguint(&limbs))
}

/// Normalise `value` into `[0, prime)` (negatives wrap) and split it into `n32`
/// little-endian 32-bit limbs.
fn field_to_limbs(value: &BigInt, prime: &BigInt, n32: usize) -> Vec<u32> {
    let mut reduced = value % prime;
    if reduced.is_negative() {
        reduced += prime;
    }
    let mut limbs = reduced
        .to_biguint()
        .expect("reduced value is non-negative")
        .to_u32_digits();
    limbs.resize(n32, 0);
    limbs
}

fn u32_limbs_to_biguint(limbs: &[u32]) -> BigUint {
    BigUint::from_slice(limbs)
}

/* -------------------------------------------------------------------------- */
/* Circom FNV signal hashing                                                   */
/* -------------------------------------------------------------------------- */

fn fnv(name: &str) -> (u32, u32) {
    /*
     * This is the Circom witness-calculator FNV-1a implementation.
     *
     * Circom splits the resulting 64-bit hash into:
     *
     *   msb = high 32 bits
     *   lsb = low 32 bits
     */
    let mut hash: u64 = 0xcbf29ce484222325;

    for byte in name.as_bytes() {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x100000001b3);
    }

    let msb = (hash >> 32) as u32;
    let lsb = hash as u32;

    (msb, lsb)
}

/* -------------------------------------------------------------------------- */
/* Tests                                                                      */
/* -------------------------------------------------------------------------- */

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    #[test]
    fn test_age_check_witness() {
        let wasm = fs::read("../../circuits/age_check/age_check_js/age_check.wasm")
            .expect("failed to read age_check.wasm");

        let mut calculator =
            WasmiWitnessCalculator::new(&wasm).expect("failed to create witness calculator");

        let inputs = vec![
            ("age".to_string(), vec![BigInt::from(25u32)]),
            ("threshold".to_string(), vec![BigInt::from(18u32)]),
        ];

        let witness = calculator
            .calculate_witness(&inputs)
            .expect("failed to calculate witness");

        println!("witness length = {}", witness.len());

        for (i, value) in witness.iter().enumerate() {
            println!("witness[{i}] = {value}");
        }

        assert_eq!(witness.len(), 15);

        /*
         * Expected Circom witness layout:
         *
         *   witness[0] = 1
         *   witness[1] = threshold = 18
         *   witness[2] = age       = 25
         *
         * We currently keep these assertions here because they will
         * immediately tell us whether the internal representation
         * decoding is correct.
         */
        assert_eq!(witness[0], Fr::from(1u64));
        assert_eq!(witness[1], Fr::from(1u64));
        assert_eq!(witness[2], Fr::from(18u64));
        assert_eq!(witness[3], Fr::from(25u64));
    }

    #[test]
    fn limbs_are_little_endian_and_fixed_width() {
        let p = BigInt::from(BigUint::from(Fr::MODULUS));
        let limbs = field_to_limbs(&BigInt::from(0x1_0000_0002u64), &p, 8);
        assert_eq!(limbs, vec![2, 1, 0, 0, 0, 0, 0, 0]);
        assert_eq!(
            u32_limbs_to_biguint(&limbs),
            BigUint::from(0x1_0000_0002u64)
        );
    }

    #[test]
    fn negative_and_oversized_values_are_reduced() {
        let p = BigInt::from(BigUint::from(Fr::MODULUS));
        let minus_one = field_to_limbs(&BigInt::from(-1), &p, 8);
        assert_eq!(BigInt::from(u32_limbs_to_biguint(&minus_one)), &p - 1);
        let wrapped = field_to_limbs(&(&p + 5), &p, 8);
        assert_eq!(wrapped, vec![5, 0, 0, 0, 0, 0, 0, 0]);
        let multiple = field_to_limbs(&(&p * 3), &p, 8);
        assert_eq!(multiple, vec![0; 8]);
    }

    fn age_check_inputs(age: i64) -> Vec<(String, Vec<BigInt>)> {
        vec![
            ("age".to_string(), vec![BigInt::from(age)]),
            ("threshold".to_string(), vec![BigInt::from(18)]),
        ]
    }

    #[test]
    fn failed_assertions_do_not_accumulate_linear_memory() {
        // Each aborted run of age_check leaves the module's stack pointer
        // advanced (~640 bytes), and `init` does not restore it. On a
        // long-lived instance that grows linear memory without bound.
        const RUNS: usize = 2_000; // 2000 * 640 B is well past the initial 704 KiB
        let wasm = fs::read("../../circuits/age_check/age_check_js/age_check.wasm").unwrap();
        let calc = WasmiWitnessCalculator::new(&wasm).unwrap();
        let bad = age_check_inputs(300); // violates the circuit's 8-bit range

        // Control: reuse one instance for every failure. This reproduces the
        // leak, which shows the measurement below can detect it.
        let (mut store, instance) = instantiate(&calc.engine, &calc.module, &calc.linker).unwrap();
        let initial = linear_memory_bytes(&store, &instance);
        for _ in 0..RUNS {
            assert!(calc.run_in(&mut store, &instance, &bad).is_err());
        }
        let leaked = linear_memory_bytes(&store, &instance);
        assert!(
            leaked > initial,
            "control did not leak: initial={initial}, after {RUNS} failures={leaked}"
        );

        // The calculator's own lifecycle: a fresh instance per call. Every
        // failing run ends with the same memory size as the module's initial
        // size, however many failures came before it.
        let (first, baseline) = calc.run_fresh(&bad);
        assert!(matches!(
            first,
            Err(WasmiWitnessError::Circom { code: 4, .. })
        ));
        assert_eq!(baseline, initial);
        for run in 0..RUNS {
            let (result, memory_bytes) = calc.run_fresh(&bad);
            assert!(result.is_err());
            assert_eq!(memory_bytes, baseline, "memory grew by failure #{run}");
        }
    }

    fn live_stores() -> isize {
        LIVE_STORES.with(|n| n.get())
    }

    #[test]
    fn calculations_release_their_stores() {
        // The memory-size test above only sees the current instance. This checks
        // that no store (and so no instance or linear memory) outlives a call.
        let wasm = fs::read("../../circuits/age_check/age_check_js/age_check.wasm").unwrap();
        assert_eq!(live_stores(), 0);

        // Control: the counter does see a store that is kept alive.
        let calc = WasmiWitnessCalculator::new(&wasm).unwrap();
        assert_eq!(live_stores(), 0, "`new` must drop its probe instance");
        let held = instantiate(&calc.engine, &calc.module, &calc.linker).unwrap();
        assert_eq!(live_stores(), 1);
        drop(held);
        assert_eq!(live_stores(), 0);

        // Success, circuit abort, validation failures: none may retain a store.
        let mut calc = calc;
        for _ in 0..25 {
            calc.calculate_witness(&age_check_inputs(25)).unwrap();
            assert!(calc.calculate_witness(&age_check_inputs(300)).is_err());
            assert!(calc.calculate_witness(&[]).is_err());
            let dup = [age_check_inputs(25), age_check_inputs(26)].concat();
            assert!(calc.calculate_witness(&dup).is_err());
        }
        assert_eq!(live_stores(), 0);
    }

    /// A minimal hand-written module with the exports the calculator needs, for
    /// tests of paths the Circom-generated modules cannot reach. It reports
    /// BN254's prime, one input signal `x` of size 1, and a 3-element witness.
    /// `set_input` and `get_witness` are WAT instruction bodies for the
    /// `setInputSignal` and `getWitness` exports.
    fn stub_module(set_input: &str, get_witness: &str) -> Vec<u8> {
        // The prime as WAT data-segment escapes (`\xx` per little-endian byte).
        let mut prime_bytes = BigUint::from(Fr::MODULUS).to_bytes_le();
        prime_bytes.resize(32, 0);
        let prime_data: String = prime_bytes.iter().map(|b| format!("\\{b:02x}")).collect();
        format!(
            r#"(module
  (import "runtime" "exceptionHandler" (func $eh (param i32)))
  (memory (export "memory") 1)
  (data (i32.const 0) "{PRIME}")
  (func (export "getFieldNumLen32") (result i32) i32.const 8)
  (func (export "getRawPrime"))
  (func (export "readSharedRWMemory") (param i32) (result i32)
    local.get 0
    i32.const 4
    i32.mul
    i32.load)
  (func (export "writeSharedRWMemory") (param i32 i32))
  (func (export "getInputSize") (result i32) i32.const 1)
  (func (export "getWitnessSize") (result i32) i32.const 3)
  (func (export "init") (param i32))
  (func (export "getInputSignalSize") (param i32 i32) (result i32) i32.const 1)
  (func (export "setInputSignal") (param i32 i32 i32) {set_input})
  (func (export "getWitness") (param i32) {get_witness}))"#,
            PRIME = prime_data,
        )
        .into_bytes()
    }

    /// `getWitness` body that stores the field element 0 (four zero i64 words).
    const WITNESS_ZERO: &str = "i32.const 0 i64.const 0 i64.store \
        i32.const 8 i64.const 0 i64.store \
        i32.const 16 i64.const 0 i64.store \
        i32.const 24 i64.const 0 i64.store";

    fn x_input() -> Vec<(String, Vec<BigInt>)> {
        vec![("x".to_string(), vec![BigInt::from(1)])]
    }

    #[test]
    fn stub_module_works_when_nothing_traps() {
        let wasm = stub_module("", WITNESS_ZERO);
        let mut calc = WasmiWitnessCalculator::new(&wasm).unwrap();
        assert_eq!(
            calc.calculate_witness(&x_input()).unwrap(),
            vec![Fr::from(0u64); 3]
        );
    }

    #[test]
    fn trap_outside_exception_handler_is_an_error_not_a_partial_witness() {
        // getWitness(0) succeeds, getWitness(1) executes `unreachable`: an
        // ordinary WASM trap with no exceptionHandler call involved.
        let get_witness =
            format!("local.get 0 i32.const 1 i32.eq if unreachable end {WITNESS_ZERO}");
        let wasm = stub_module("", &get_witness);
        let mut calc = WasmiWitnessCalculator::new(&wasm).unwrap();

        let err = calc.calculate_witness(&x_input()).unwrap_err();
        assert!(
            matches!(err, WasmiWitnessError::Execution(ref m) if m.contains("getWitness")),
            "{err}"
        );
        // And the calculator still reports the same error on the next call
        // rather than panicking or returning something.
        assert!(matches!(
            calc.calculate_witness(&x_input()),
            Err(WasmiWitnessError::Execution(_))
        ));
    }

    #[test]
    fn signal_not_found_from_the_module_is_propagated() {
        // The module accepts the size query but rejects the assignment with
        // exception code 1, as the Circom-generated setInputSignal does for a
        // name it does not know. The host must surface that, not swallow it.
        let wasm = stub_module("i32.const 1 call $eh", WITNESS_ZERO);
        let mut calc = WasmiWitnessCalculator::new(&wasm).unwrap();
        let err = calc.calculate_witness(&x_input()).unwrap_err();
        assert!(
            matches!(
                err,
                WasmiWitnessError::Circom {
                    code: 1,
                    reason: "signal not found",
                    ..
                }
            ),
            "{err}"
        );
    }

    #[test]
    fn prime_is_read_through_the_wasm_interface() {
        let wasm = fs::read("../../circuits/age_check/age_check_js/age_check.wasm").unwrap();
        let calculator = WasmiWitnessCalculator::new(&wasm).unwrap();
        assert_eq!(
            calculator.prime(),
            &BigInt::from(BigUint::from(Fr::MODULUS))
        );
    }
}
