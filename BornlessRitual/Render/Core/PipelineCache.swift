//
//  PipelineCache.swift
//  Bornless Ritual — pipeline-state cache keyed by function name and function-constant
//  variant (RENDER_CONTRACT §1 `PipelineCache`, function constants per `Common.h`).
//
//  Role: passes ask for compute / render pipelines by shader function name; the cache
//  specialises them with the current `PipelineVariant` (render path, MetalFX on/off,
//  debug view) and memoises the result so a path switch or resize rebuild is cheap.
//

import Foundation
import Metal

// MARK: - Function constants

/// Function-constant indices shared with `Shaders/Common.h` (`kRenderPath`, `kMetalFX`, `kDebugView`).
enum FunctionConstantIndex: Int {
    /// `constant uint kRenderPath [[function_constant(0)]]`
    case renderPath = 0
    /// `constant bool kMetalFX [[function_constant(1)]]`
    case metalFX = 1
    /// `constant uint kDebugView [[function_constant(2)]]`
    case debugView = 2
}

/// The set of function-constant values a pipeline is specialised for.
struct PipelineVariant: Hashable, Sendable {
    /// Render path (function constant 0).
    var renderPath: RenderPath
    /// MetalFX temporal upscaling active (function constant 1).
    var metalFX: Bool
    /// Debug visualisation selector (function constant 2).
    var debugView: DebugView

    /// Default variant: RT path, MetalFX on, no debug view.
    static let `default` = PipelineVariant(renderPath: .rt, metalFX: true, debugView: .none)

    /// Builds the `MTLFunctionConstantValues` for this variant.
    func makeConstantValues() -> MTLFunctionConstantValues {
        let values = MTLFunctionConstantValues()
        var renderPathValue: UInt32 = renderPath.shaderValue
        var metalFXValue: Bool = metalFX
        var debugViewValue: UInt32 = debugView.shaderValue
        values.setConstantValue(&renderPathValue, type: .uint, index: FunctionConstantIndex.renderPath.rawValue)
        values.setConstantValue(&metalFXValue, type: .bool, index: FunctionConstantIndex.metalFX.rawValue)
        values.setConstantValue(&debugViewValue, type: .uint, index: FunctionConstantIndex.debugView.rawValue)
        return values
    }
}

/// Errors raised while building pipelines.
enum PipelineError: Error, CustomStringConvertible {
    /// `MTLLibrary.makeFunction` found no function of that name.
    case missingFunction(String)
    /// The pipeline descriptor had no label to cache by.
    case unlabeledRenderDescriptor

    var description: String {
        switch self {
        case .missingFunction(let name): return "Shader function '\(name)' not found in the default library"
        case .unlabeledRenderDescriptor: return "Render pipeline descriptors must carry a label"
        }
    }
}

// MARK: - PipelineCache

/// Memoising factory for compute and render pipeline states.
final class PipelineCache {
    /// Device the pipelines belong to.
    let device: MTLDevice
    /// Library the functions come from (the app's default library).
    let library: MTLLibrary
    /// Variant applied when a pass asks for a pipeline without explicit constants.
    /// The Renderer sets this before calling `RenderPass.build`.
    var variant: PipelineVariant = .default

    private struct ComputeKey: Hashable {
        let function: String
        let variant: PipelineVariant?
    }
    private struct RenderKey: Hashable {
        let label: String
        let variant: PipelineVariant
    }

    private var computeStates: [ComputeKey: MTLComputePipelineState] = [:]
    private var renderStates: [RenderKey: MTLRenderPipelineState] = [:]
    private var constantValuesByVariant: [PipelineVariant: MTLFunctionConstantValues] = [:]
    private var variantByConstantValues: [ObjectIdentifier: PipelineVariant] = [:]

    /// Creates an empty cache.
    init(device: MTLDevice, library: MTLLibrary) {
        self.device = device
        self.library = library
    }

    // MARK: Function constants

    /// A shared `MTLFunctionConstantValues` for `variant` (one instance per variant, so
    /// passes can pass it back to `compute(_:constants:)` and still hit the cache).
    func constantValues(for variant: PipelineVariant) -> MTLFunctionConstantValues {
        if let existing = constantValuesByVariant[variant] {
            return existing
        }
        let values = variant.makeConstantValues()
        constantValuesByVariant[variant] = values
        variantByConstantValues[ObjectIdentifier(values)] = variant
        return values
    }

    /// Constant values for the current `variant`.
    var currentConstantValues: MTLFunctionConstantValues {
        constantValues(for: variant)
    }

    // MARK: Functions

    /// Specialised function `name` for `variant` (or unspecialised when `variant` is nil).
    func function(_ name: String, variant: PipelineVariant?) throws -> MTLFunction {
        if let variant = variant {
            return try library.makeFunction(name: name, constantValues: constantValues(for: variant))
        }
        guard let function = library.makeFunction(name: name) else {
            throw PipelineError.missingFunction(name)
        }
        return function
    }

    /// Specialised function for the current `variant`.
    func function(_ name: String) throws -> MTLFunction {
        try function(name, variant: variant)
    }

    // MARK: Compute pipelines

    /// Compute pipeline for `fn` specialised with the current `variant` (cached).
    func compute(_ fn: String) throws -> MTLComputePipelineState {
        try compute(fn, variant: variant)
    }

    /// Compute pipeline for `fn` specialised with an explicit `variant` (cached).
    func compute(_ fn: String, variant: PipelineVariant?) throws -> MTLComputePipelineState {
        let key = ComputeKey(function: fn, variant: variant)
        if let cached = computeStates[key] {
            return cached
        }
        let descriptor = MTLComputePipelineDescriptor()
        descriptor.computeFunction = try function(fn, variant: variant)
        descriptor.label = fn
        descriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth = true
        let state = try device.makeComputePipelineState(descriptor: descriptor, options: [], reflection: nil)
        computeStates[key] = state
        return state
    }

    /// Contract entry point: `compute(_ fn:constants:)`. Constant-value objects obtained
    /// from `constantValues(for:)` map back to their variant and hit the cache; a foreign
    /// `MTLFunctionConstantValues` is honoured but compiled uncached. `nil` means the
    /// current `variant`.
    func compute(_ fn: String, constants: MTLFunctionConstantValues?) throws -> MTLComputePipelineState {
        guard let constants = constants else {
            return try compute(fn, variant: variant)
        }
        if let knownVariant = variantByConstantValues[ObjectIdentifier(constants)] {
            return try compute(fn, variant: knownVariant)
        }
        let function = try library.makeFunction(name: fn, constantValues: constants)
        return try device.makeComputePipelineState(function: function)
    }

    // MARK: Render pipelines

    /// Render pipeline for `desc`, cached by `desc.label` and the current `variant`.
    /// The descriptor's functions must already be set (use `function(_:)`).
    func render(_ desc: MTLRenderPipelineDescriptor) throws -> MTLRenderPipelineState {
        guard let label = desc.label, !label.isEmpty else {
            throw PipelineError.unlabeledRenderDescriptor
        }
        let key = RenderKey(label: label, variant: variant)
        if let cached = renderStates[key] {
            return cached
        }
        let state = try device.makeRenderPipelineState(descriptor: desc)
        renderStates[key] = state
        return state
    }

    /// Convenience: builds a render pipeline from vertex/fragment function names with the
    /// current variant, letting the caller configure attachments in `configure`.
    func render(label: String, vertexFunction: String, fragmentFunction: String?,
                configure: (MTLRenderPipelineDescriptor) -> Void) throws -> MTLRenderPipelineState {
        let key = RenderKey(label: label, variant: variant)
        if let cached = renderStates[key] {
            return cached
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = label
        descriptor.vertexFunction = try function(vertexFunction)
        if let fragmentFunction = fragmentFunction {
            descriptor.fragmentFunction = try function(fragmentFunction)
        }
        configure(descriptor)
        let state = try device.makeRenderPipelineState(descriptor: descriptor)
        renderStates[key] = state
        return state
    }

    // MARK: Maintenance

    /// Drops every cached state (e.g. when the library is reloaded). Pipelines still
    /// referenced by passes stay alive until those passes rebuild.
    func invalidate() {
        computeStates.removeAll()
        renderStates.removeAll()
    }

    /// Number of cached pipeline states (debug panel).
    var cachedStateCount: Int {
        computeStates.count + renderStates.count
    }
}
