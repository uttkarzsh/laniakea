use ark_bn254::Fr;
use ark_ff::PrimeField;
use num_bigint::BigInt;
use num_traits::{Signed, ToPrimitive, Zero};
use thiserror::Error;
use wasmi::{Caller, Engine, Linker, Memory, Module, Store};

/// Errors specific to wasmi-witness crate
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
}

/// Low-level wasmi-based witness calculator.
/// Produces BN254 Fr witness vector directly.
/// No dependency on laniakea-core.
pub struct WasmiWitnessCalculator {
    instance: wasmi::Instance,
    store: Store<()>,
    memory: Memory,
    n32: u32,
    prime: BigInt,
    num_public: usize,
}

impl WasmiWitnessCalculator {
    /// Create from raw WASM bytes only (no R1CS needed).
    pub fn new(wasm_bytes: Vec<u8>) -> Result<Self, WasmiWitnessError> {
        let engine = Engine::default();
        let module = Module::new(&engine, &wasm_bytes)
            .map_err(|e| WasmiWitnessError::Module(e.to_string()))?;

        let mut store = Store::new(&engine, ());
        let mut linker = Linker::new(&engine);

        // Define no-op host imports required by Circom 2.0 WASM
        linker
            .func_wrap(
                "runtime",
                "exceptionHandler",
                |_: Caller<'_, ()>, _: i32| {},
            )
            .map_err(|e| WasmiWitnessError::Instantiation(e.to_string()))?;
        linker
            .func_wrap("runtime", "printErrorMessage", |_: Caller<'_, ()>| {})
            .map_err(|e| WasmiWitnessError::Instantiation(e.to_string()))?;
        linker
            .func_wrap("runtime", "writeBufferMessage", |_: Caller<'_, ()>| {})
            .map_err(|e| WasmiWitnessError::Instantiation(e.to_string()))?;
        linker
            .func_wrap("runtime", "showSharedRWMemory", |_: Caller<'_, ()>| {})
            .map_err(|e| WasmiWitnessError::Instantiation(e.to_string()))?;

        let instance = linker
            .instantiate_and_start(&mut store, &module)
            .map_err(|e| WasmiWitnessError::Instantiation(e.to_string()))?;

        let memory = instance
            .get_memory(&store, "memory")
            .ok_or_else(|| WasmiWitnessError::Instantiation("memory export not found".into()))?;

        // Call init() to initialize the circuit
        let init = instance
            .get_typed_func::<(), ()>(&store, "init")
            .map_err(|e| WasmiWitnessError::Execution(e.to_string()))?;
        init.call(&mut store, ())
            .map_err(|e| WasmiWitnessError::Execution(e.to_string()))?;

        // Get field parameters
        let get_field_len = instance
            .get_typed_func::<(), i32>(&store, "getFieldNumLen32")
            .map_err(|e| WasmiWitnessError::Execution(e.to_string()))?;
        let n32 = get_field_len
            .call(&mut store, ())
            .map_err(|e| WasmiWitnessError::Execution(e.to_string()))? as u32;

        // Read prime modulus from WASM memory
        let get_raw_prime = instance
            .get_typed_func::<(), i32>(&store, "getRawPrime")
            .map_err(|e| WasmiWitnessError::Execution(e.to_string()))?;
        let prime_ptr = get_raw_prime
            .call(&mut store, ())
            .map_err(|e| WasmiWitnessError::Execution(e.to_string()))?;

        // Read n32 * 4 bytes (u32 array) from memory at prime_ptr
        let mut prime_arr = vec![0u32; n32 as usize];
        for i in 0..n32 as usize {
            let mut bytes = [0u8; 4];
            memory
                .read(&store, prime_ptr as usize + i * 4, &mut bytes)
                .map_err(|e| WasmiWitnessError::MemoryRead(e.to_string()))?;
            prime_arr[i] = u32::from_le_bytes(bytes);
        }

        // Convert to BigInt (little-endian u32 limbs)
        let mut prime = BigInt::from(0);
        for &limb in prime_arr.iter().rev() {
            prime = (prime << 32) + BigInt::from(limb);
        }

        // Get number of public inputs
        let get_input_size = instance
            .get_typed_func::<(), i32>(&store, "getInputSize")
            .map_err(|e| WasmiWitnessError::Execution(e.to_string()))?;
        let num_public = get_input_size
            .call(&mut store, ())
            .map_err(|e| WasmiWitnessError::Execution(e.to_string()))?
            as usize;

        Ok(Self {
            instance,
            store,
            memory,
            n32,
            prime,
            num_public,
        })
    }

    /// Calculate witness as BigInts, then convert to BN254 Fr.
    pub fn calculate_witness(
        &mut self,
        inputs: &[(String, Vec<BigInt>)],
    ) -> Result<Vec<Fr>, WasmiWitnessError> {
        // Write inputs via setInputSignal
        let set_input_signal = self
            .instance
            .get_typed_func::<(i32, i32, i32), ()>(&self.store, "setInputSignal")
            .map_err(|e| WasmiWitnessError::Execution(e.to_string()))?;

        let get_input_signal_size = self
            .instance
            .get_typed_func::<(i32, i32), i32>(&self.store, "getInputSignalSize")
            .map_err(|e| WasmiWitnessError::Execution(e.to_string()))?;

        for (name, values) in inputs {
            let (msb, lsb) = fnv(name);
            let signal_size = get_input_signal_size
                .call(&mut self.store, (msb, lsb))
                .map_err(|e| WasmiWitnessError::Execution(e.to_string()))?;

            for (i, value) in values.iter().enumerate() {
                if i >= signal_size as usize {
                    break; // safety
                }
                // Convert BigInt to u32 limbs (little-endian)
                let limbs = bigint_to_u32_limbs(value, self.n32 as usize);
                let write_rw = self
                    .instance
                    .get_typed_func::<(i32, i32), ()>(&self.store, "writeSharedRWMemory")
                    .map_err(|e| WasmiWitnessError::Execution(e.to_string()))?;
                for (j, limb) in limbs.iter().enumerate() {
                    write_rw
                        .call(&mut self.store, (j as i32, *limb as i32))
                        .map_err(|e| WasmiWitnessError::Execution(e.to_string()))?;
                }
                set_input_signal
                    .call(&mut self.store, (msb, lsb, i as i32))
                    .map_err(|e| WasmiWitnessError::Execution(e.to_string()))?;
            }
        }

        // Get witness size
        let get_witness_size = self
            .instance
            .get_typed_func::<(), i32>(&self.store, "getWitnessSize")
            .map_err(|e| WasmiWitnessError::Execution(e.to_string()))?;
        let witness_size = get_witness_size
            .call(&mut self.store, ())
            .map_err(|e| WasmiWitnessError::Execution(e.to_string()))?
            as usize;

        // Read witness elements
        let mut witness_bigints = Vec::with_capacity(witness_size);
        let get_witness = self
            .instance
            .get_typed_func::<i32, ()>(&self.store, "getWitness")
            .map_err(|e| WasmiWitnessError::Execution(e.to_string()))?;
        let read_rw = self
            .instance
            .get_typed_func::<i32, i32>(&self.store, "readSharedRWMemory")
            .map_err(|e| WasmiWitnessError::Execution(e.to_string()))?;

        for i in 0..witness_size {
            get_witness
                .call(&mut self.store, i as i32)
                .map_err(|e| WasmiWitnessError::Execution(e.to_string()))?;
            let mut limbs = vec![0u32; self.n32 as usize];
            for j in 0..self.n32 as usize {
                let val = read_rw
                    .call(&mut self.store, j as i32)
                    .map_err(|e| WasmiWitnessError::Execution(e.to_string()))?;
                limbs[j] = val as u32;
            }
            witness_bigints.push(u32_limbs_to_bigint(&limbs));
        }

        // Convert BigInt -> Fr (mod prime)
        let modulus = <Fr as PrimeField>::MODULUS;
        let modulus_biguint: num_bigint::BigUint = modulus.into();
        let witness = witness_bigints
            .into_iter()
            .map(|w| {
                let w = if w.is_negative() {
                    (&modulus_biguint - w.abs().to_biguint().unwrap())
                } else {
                    w.to_biguint().unwrap()
                };
                Fr::from(w)
            })
            .collect();

        Ok(witness)
    }

    pub fn num_public_inputs(&self) -> usize {
        self.num_public
    }
}

/// FNV hash for signal name lookup (matches Circom's FNV implementation)
fn fnv(name: &str) -> (i32, i32) {
    let mut hash = 0x811c9dc5u64;
    for byte in name.as_bytes() {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x01000193);
    }
    let msb = (hash >> 32) as i32;
    let lsb = hash as i32;
    (msb, lsb)
}

/// Convert BigInt to little-endian u32 limbs (fixed width)
fn bigint_to_u32_limbs(value: &BigInt, n32: usize) -> Vec<u32> {
    let mut limbs = vec![0u32; n32];
    let mut rem = value.clone();
    let radix = BigInt::from(0x100000000u64);
    let mut i = n32;
    while !rem.is_zero() && i > 0 {
        i -= 1;
        limbs[i] = (&rem % &radix).to_u32().unwrap_or(0);
        rem /= &radix;
    }
    limbs
}

/// Convert little-endian u32 limbs to BigInt
fn u32_limbs_to_bigint(limbs: &[u32]) -> BigInt {
    let mut res = BigInt::from(0);
    let radix = BigInt::from(0x100000000u64);
    for &limb in limbs.iter().rev() {
        res = res * &radix + BigInt::from(limb);
    }
    res
}
