/// Queue-confined Float32 complex DFT. The numerical analyzers do not own an OS backend.
/// Forward, unnormalized: X[k] = sum(x[n] * exp(-2*pi*i*k*n/size)).
/// All four arrays contain `size` samples. The backend adds no windowing,
/// downmixing or normalization; analyzers already perform those operations.
protocol SpectrumTransform: AnyObject {
    var size: Int { get }
    func forward(real: inout [Float], imaginary: inout [Float],
                 realOutput: inout [Float], imaginaryOutput: inout [Float])
}
