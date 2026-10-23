// Runs every case in cases.json through Circom's own generated JS witness
// calculator and records either the witness (decimal strings) or the error.
// Regenerate with:  node circuits/reference/gen_reference.js
// The Rust tests in crates/wasmi-witness/tests compare against this output.
const fs = require("fs");
const path = require("path");

const root = path.join(__dirname, "..");
const circuits = {
  age_check: "age_check/age_check_js/age_check.wasm",
  witness_probe: "witness_probe/witness_probe_js/witness_probe.wasm",
};
const builders = {
  age_check: require(path.join(root, "age_check/age_check_js/witness_calculator.js")),
  witness_probe: require(path.join(root, "witness_probe/witness_probe_js/witness_calculator.js")),
};

(async () => {
  const cases = JSON.parse(fs.readFileSync(path.join(__dirname, "cases.json"), "utf8"));
  const out = [];
  for (const c of cases) {
    const wasm = fs.readFileSync(path.join(root, circuits[c.circuit]));
    const wc = await builders[c.circuit](wasm);
    const rec = { circuit: c.circuit, name: c.name, inputs: c.inputs };
    try {
      const w = await wc.calculateWitness(c.inputs, 0);
      rec.witness = w.map((x) => x.toString());
    } catch (e) {
      rec.error = String(e.message || e).trim();
    }
    out.push(rec);
  }
  fs.writeFileSync(path.join(__dirname, "reference_witnesses.json"), JSON.stringify(out, null, 1) + "\n");
  for (const r of out) console.log(r.circuit.padEnd(14), r.name.padEnd(42), r.witness ? "OK  len=" + r.witness.length : "ERR " + JSON.stringify(r.error));
})();
