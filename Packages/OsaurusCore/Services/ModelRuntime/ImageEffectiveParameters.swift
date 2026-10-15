import Foundation

/// Values used by the pipeline, rather than the caller's requested values.
/// Optional fields are absent when the operation does not use that parameter.
public struct ImageEffectiveParameters: Sendable, Codable, Equatable {
    public var width: Int
    public var height: Int
    public var steps: Int
    public var guidance: Float
    public var seed: UInt64
    public var sampler: String?
    public var scheduler: String?
    public var shift: Float?
    public var strength: Float?
    public var scale: Int?
    public var modelRevision: String?
    /// A bundle's fixed sigma grid, excluding the terminal zero.
    public var sampleSigmas: [Float]?

    /// Tool-result projection; keeps UInt64 seeds integral and omits unknown values.
    var jsonObject: [String: Any] {
        var result: [String: Any] = [
            "width": width, "height": height, "steps": steps, "guidance": guidance, "seed": seed,
        ]
        if let sampler { result["sampler"] = sampler }
        if let scheduler { result["scheduler"] = scheduler }
        if let shift { result["shift"] = shift }
        if let strength { result["strength"] = strength }
        if let scale { result["scale"] = scale }
        if let modelRevision { result["modelRevision"] = modelRevision }
        if let sampleSigmas { result["sampleSigmas"] = sampleSigmas }
        return result
    }

    /// Do not label requested values as actual in Insights. Only replace a
    /// shared field when every returned image reports the same effective value.
    static func activityDetails(_ requested: [String: String], images: [GeneratedImage]) -> [String: String] {
        let parameters = images.compactMap(\.effectiveParameters)
        guard parameters.count == images.count, let first = parameters.first else { return requested }
        var result = requested
        if parameters.allSatisfy({ $0.steps == first.steps }) {
            result["requested_steps"] = requested["steps"]
            result["steps"] = String(first.steps)
        }
        if parameters.allSatisfy({ $0.width == first.width && $0.height == first.height }) {
            result["requested_size"] = requested["size"]
            result["size"] = "\(first.width)x\(first.height)"
        }
        return result
    }

    public init(
        width: Int, height: Int, steps: Int, guidance: Float, seed: UInt64,
        sampler: String? = nil, scheduler: String? = nil, shift: Float? = nil,
        strength: Float? = nil, scale: Int? = nil, modelRevision: String? = nil,
        sampleSigmas: [Float]? = nil
    ) {
        self.width = width
        self.height = height
        self.steps = steps
        self.guidance = guidance
        self.seed = seed
        self.sampler = sampler
        self.scheduler = scheduler
        self.shift = shift
        self.strength = strength
        self.scale = scale
        self.modelRevision = modelRevision
        self.sampleSigmas = sampleSigmas
    }
}
