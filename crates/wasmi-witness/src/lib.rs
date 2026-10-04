use ark_bn254::Fr;
use ark_ff::PrimeField;
use num_bigint::BigInt;
use num_traits::{Signed, ToPrimitive, Zero};
use thiserror::Error;
use wasmi::{Caller, Engine, Linker, Memory, Module, Store};

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

pub struct WasmiWitnessCalculator {
    instance: wasmi::Instance,
    store: Store<()>,
    memory: Memory,
    n32: u32,
    prime: BigInt,
    num_public: usize,
}

impl WasmiWitnessCalculator {
    pub fn new(wasm_bytes: &[u8]) -> Result<Self, WasmiWitnessError> {
        let engine = Engine::default();

        let module = Module::new(&engine, &mut &wasm_bytes[..])
            .map_err(|e| WasmiWitnessError::Module(e.to_string()))?;

        let mut store = Store::new(&engine, ());

        let mut linker = Linker::new(&engine);

        /*
         * Circom 2 WASM runtime imports.
         *
         * The generated age_check.wasm imports these functions but
         * does not actually require WASI.
         */
        linker
            .func_wrap(
                "runtime",
                "exceptionHandler",
                |_caller: Caller<'_, ()>, _code: i32| {},
            )
            .map_err(|e| WasmiWitnessError::Instantiation(e.to_string()))?;

        linker
            .func_wrap("runtime", "printErrorMessage", |_caller: Caller<'_, ()>| {})
            .map_err(|e| WasmiWitnessError::Instantiation(e.to_string()))?;

        linker
            .func_wrap(
                "runtime",
                "writeBufferMessage",
                |_caller: Caller<'_, ()>| {},
            )
            .map_err(|e| WasmiWitnessError::Instantiation(e.to_string()))?;

        linker
            .func_wrap(
                "runtime",
                "showSharedRWMemory",
                |_caller: Caller<'_, ()>| {},
            )
            .map_err(|e| WasmiWitnessError::Instantiation(e.to_string()))?;

        let instance = linker
            .instantiate_and_start(&mut store, &module)
            .map_err(|e| WasmiWitnessError::Instantiation(e.to_string()))?;

        /*
         * Unlike ark-circom's Wasmer path, this Circom 2 module exports
         * its own memory.
         */
        let memory = instance.get_memory(&store, "memory").ok_or_else(|| {
            WasmiWitnessError::Instantiation("WASM module does not export `memory`".to_string())
        })?;

        /*
         * Get field element size.
         *
         * For BN254 Circom WASM this is 8 32-bit limbs.
         */
        let get_field_num_len32 = instance
            .get_typed_func::<(), i32>(&store, "getFieldNumLen32")
            .map_err(|e| WasmiWitnessError::Instantiation(e.to_string()))?;

        let n32 = get_field_num_len32
            .call(&mut store, ())
            .map_err(|e| WasmiWitnessError::Execution(e.to_string()))? as u32;

        /*
         * Read the field prime.
         *
         * Circom writes the prime into the shared RW memory area.
         */
        let get_raw_prime = instance
            .get_typed_func::<(), ()>(&store, "getRawPrime")
            .map_err(|e| WasmiWitnessError::Instantiation(e.to_string()))?;

        get_raw_prime
            .call(&mut store, ())
            .map_err(|e| WasmiWitnessError::Execution(e.to_string()))?;

        let mut prime_limbs = Vec::with_capacity(n32 as usize);

        for i in 0..n32 {
            let limb = read_i32(&memory, &store, 1984 + (i as usize) * 4)
                .map_err(|e| WasmiWitnessError::MemoryRead(e))?;

            prime_limbs.push(limb as u32);
        }

        let prime = u32_limbs_to_bigint(&prime_limbs);

        /*
         * Number of public inputs/signals.
         *
         * age_check.wasm reports 2:
         *
         *   age
         *   threshold
         *
         * Note that this is the number of input signals, not necessarily
         * the number of public witness elements.
         */
        let get_input_size = instance
            .get_typed_func::<(), i32>(&store, "getInputSize")
            .map_err(|e| WasmiWitnessError::Instantiation(e.to_string()))?;

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

    pub fn calculate_witness(
        &mut self,
        inputs: &[(String, Vec<BigInt>)],
    ) -> Result<Vec<Fr>, WasmiWitnessError> {
        /*
         * Circom 2 lifecycle:
         *
         *   init( sanity_check )
         *   setInputSignal(...)
         *   getWitnessSize()
         *   getWitness(...)
         */
        let init = self
            .instance
            .get_typed_func::<i32, ()>(&self.store, "init")
            .map_err(|e| WasmiWitnessError::Instantiation(e.to_string()))?;

        init.call(&mut self.store, 1)
            .map_err(|e| WasmiWitnessError::Execution(format!("init failed: {e}")))?;

        let set_input_signal = self
            .instance
            .get_typed_func::<(i32, i32, i32), ()>(&self.store, "setInputSignal")
            .map_err(|e| WasmiWitnessError::Instantiation(e.to_string()))?;

        /*
         * Circom's generated WASM uses the shared RW memory for passing
         * field elements into setInputSignal.
         */
        let write_shared_rw_memory = self
            .instance
            .get_typed_func::<(i32, i32), ()>(&self.store, "writeSharedRWMemory")
            .map_err(|e| WasmiWitnessError::Instantiation(e.to_string()))?;

        /*
         * Set every input.
         *
         * Circom uses FNV-1a hashing of the signal name to identify
         * the signal internally.
         */
        for (name, values) in inputs {
            let (msb, lsb) = fnv(name);

            for (index, value) in values.iter().enumerate() {
                let limbs = bigint_to_u32_limbs(value, self.n32 as usize);

                /*
                 * For the generated Circom 2 WASM, shared RW memory
                 * receives little-endian 32-bit limbs.
                 */
                for (j, limb) in limbs.iter().enumerate() {
                    write_shared_rw_memory
                        .call(&mut self.store, (j as i32, *limb as i32))
                        .map_err(|e| {
                            WasmiWitnessError::Execution(format!(
                                "writeSharedRWMemory({j}, {limb}) failed: {e}"
                            ))
                        })?;
                }

                set_input_signal
                    .call(&mut self.store, (msb as i32, lsb as i32, index as i32))
                    .map_err(|e| {
                        WasmiWitnessError::Execution(format!(
                            "setInputSignal({msb}, {lsb}, {index}) failed: {e}"
                        ))
                    })?;
            }
        }

        /*
         * getWitnessSize() tells us how many witness elements exist.
         */
        let get_witness_size = self
            .instance
            .get_typed_func::<(), i32>(&self.store, "getWitnessSize")
            .map_err(|e| WasmiWitnessError::Instantiation(e.to_string()))?;

        let witness_size = get_witness_size
            .call(&mut self.store, ())
            .map_err(|e| WasmiWitnessError::Execution(e.to_string()))?
            as usize;

        /*
         * The generated WASM's getWitness implementation accesses:
         *
         *   pointer_table = 6140
         *
         * and resolves:
         *
         *   ptr = *(6140 + witness_index * 4)
         *   c   = 6204 + ptr * 40
         *
         * before calling:
         *
         *   Fr_copy(1984, c)
         *   Fr_toLongNormal(1984)
         *
         * We inspect that storage directly so we don't guess the
         * internal Circom Fr representation.
         */
        for i in 0..witness_size {
            let ptr_addr = 6140usize + i * 4;

            let ptr = read_u32(&self.memory, &self.store, ptr_addr)
                .map_err(WasmiWitnessError::MemoryRead)? as usize;

            let c = 6204usize + ptr * 40;

            let _storage = read_bytes(&self.memory, &self.store, c, 40)
                .map_err(WasmiWitnessError::MemoryRead)?;
        }

        let get_witness = self
            .instance
            .get_typed_func::<i32, ()>(&self.store, "getWitness")
            .map_err(|e| WasmiWitnessError::Instantiation(e.to_string()))?;

        let mut witness = Vec::with_capacity(witness_size);

        for i in 0..witness_size {
            get_witness.call(&mut self.store, i as i32).map_err(|e| {
                WasmiWitnessError::Execution(format!("getWitness({i}) failed: {e}"))
            })?;

            /*
             * getWitness writes its temporary Fr object at address 1984.
             *
             * From the generated WAT:
             *
             *   Fr_copy(1984, c)
             *   Fr_toLongNormal(1984)
             *
             * Fr_toLongNormal then reads a signed 32-bit value from:
             *
             *   1984 + 8
             *
             * via i64.load32_s.
             *
             * We therefore inspect the complete object first.
             */
            let _raw = read_bytes(&self.memory, &self.store, 1984, 40)
                .map_err(WasmiWitnessError::MemoryRead)?;

            /*
             * The immediate scalar consumed by Fr_toLongNormal is at
             * offset +8.
             *
             * Do not interpret the entire 40-byte object as eight
             * independent field limbs.
             */
            let scalar =
                read_i32(&self.memory, &self.store, 1992).map_err(WasmiWitnessError::MemoryRead)?;

            let value = BigInt::from(scalar);

            let field_element = bigint_to_fr(&value, &self.prime)?;

            witness.push(field_element);
        }

        Ok(witness)
    }

    pub fn num_public(&self) -> usize {
        self.num_public
    }

    pub fn prime(&self) -> &BigInt {
        &self.prime
    }
}

/* -------------------------------------------------------------------------- */
/* Memory helpers                                                             */
/* -------------------------------------------------------------------------- */

fn read_bytes(
    memory: &Memory,
    store: &Store<()>,
    offset: usize,
    len: usize,
) -> Result<Vec<u8>, String> {
    let data = memory.data(store);

    let end = offset
        .checked_add(len)
        .ok_or_else(|| "memory offset overflow".to_string())?;

    if end > data.len() {
        return Err(format!(
            "memory read out of bounds: offset={offset}, len={len}, memory_size={}",
            data.len()
        ));
    }

    Ok(data[offset..end].to_vec())
}

fn read_u32(memory: &Memory, store: &Store<()>, offset: usize) -> Result<u32, String> {
    let bytes = read_bytes(memory, store, offset, 4)?;

    Ok(u32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
}

fn read_i32(memory: &Memory, store: &Store<()>, offset: usize) -> Result<i32, String> {
    Ok(read_u32(memory, store, offset)? as i32)
}

/* -------------------------------------------------------------------------- */
/* BigInt / field helpers                                                     */
/* -------------------------------------------------------------------------- */

fn bigint_to_u32_limbs(value: &BigInt, n32: usize) -> Vec<u32> {
    let mut limbs = vec![0u32; n32];

    let radix = BigInt::from(0x1_0000_0000u64);
    let mut remainder = value.clone();

    for limb in limbs.iter_mut() {
        *limb = (&remainder % &radix).to_u32().unwrap_or(0);

        remainder /= &radix;
    }

    limbs
}

fn u32_limbs_to_bigint(limbs: &[u32]) -> BigInt {
    let mut result = BigInt::zero();
    let radix = BigInt::from(0x1_0000_0000u64);

    for &limb in limbs.iter().rev() {
        result = result * &radix + BigInt::from(limb);
    }

    result
}

fn bigint_to_fr(value: &BigInt, prime: &BigInt) -> Result<Fr, WasmiWitnessError> {
    let mut value = value.clone();

    /*
     * Circom field elements are modulo the BN254 scalar field prime.
     */
    value %= prime;

    if value.is_negative() {
        value += prime;
    }

    let bytes = value.to_bytes_le().1;

    Ok(Fr::from_le_bytes_mod_order(&bytes))
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
}
