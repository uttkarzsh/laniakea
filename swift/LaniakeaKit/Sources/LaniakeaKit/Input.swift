import Foundation
internal import _LaniakeaBindings

/// The values of one circuit input signal.
///
/// A scalar signal takes one value and an array signal takes several, flattened
/// under the array's name (`"v"`, not `"v[0]"`). Values are field elements of
/// BN254's scalar field: whole numbers from 0 up to, but not including,
/// 21888242871839275222246405745257275088548364400416034343698204186575808495617.
///
/// Nothing is validated here. The prover checks every value when you call
/// `Prover.prove`, so there is one rule: a value that is not a canonical decimal
/// (negative, with a sign or leading zeros, not a number, or too large) comes back as
/// `LaniakeaError.invalidInputValue` naming the signal, the position and the text.
public struct Input: Sendable, Hashable {
    /// The values as decimal strings, the form the prover takes.
    public let values: [String]

    init(values: [String]) {
        self.values = values
    }

    /// One value from an integer. Negative integers are rejected by the prover; the
    /// circuit's field has no negative numbers.
    public static func integer(_ value: Int) -> Input {
        Input(values: [String(value)])
    }

    /// One value from a canonical decimal string. The way to pass values above `Int.max`.
    public static func decimal(_ value: String) -> Input {
        Input(values: [value])
    }

    /// An array signal from integers.
    public static func integers(_ values: [Int]) -> Input {
        Input(values: values.map(String.init))
    }

    /// An array signal from canonical decimal strings.
    public static func decimals(_ values: [String]) -> Input {
        Input(values: values)
    }
}

extension Input {
    /// The generated bindings' form of a dictionary of inputs, in name order so that
    /// the same call always sends the same sequence.
    static func ffiInputs(_ inputs: [String: Input]) -> [CircuitInput] {
        inputs.sorted { $0.key < $1.key }.map { CircuitInput(name: $0.key, values: $0.value.values) }
    }
}
