import Accelerate

final class AccelerateSpectrumTransform: SpectrumTransform {
    let size: Int
    private let setup: vDSP_DFT_Setup
    init(size: Int) throws {
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(size), .FORWARD) else {
            throw AudioAnalysisError.fftUnavailable
        }
        self.size = size; self.setup = setup
    }
    deinit { vDSP_DFT_DestroySetup(setup) }
    func forward(real: inout [Float], imaginary: inout [Float],
                 realOutput: inout [Float], imaginaryOutput: inout [Float]) {
        vDSP_DFT_Execute(setup, &real, &imaginary, &realOutput, &imaginaryOutput)
    }
}

// Native convenience composition. Shared analyzers only require SpectrumTransform.
extension AudioFeatureAnalyzer {
    convenience init() throws { try self.init(transform: AccelerateSpectrumTransform(size: Self.windowSize)) }
}
extension MelodyAnalyzer {
    convenience init() throws { try self.init(transform: AccelerateSpectrumTransform(size: Self.windowSize)) }
}
extension AudioAnalysisPipeline {
    convenience init() throws { try self.init(features: AudioFeatureAnalyzer(), melody: MelodyAnalyzer()) }
}
