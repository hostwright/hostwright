import HostwrightWASIProviderSDK
#if os(WASI)
  import WASILibc
#else
  import Darwin
#endif

private func hex(_ bytes: [UInt8]) -> String {
  let digits = Array("0123456789abcdef".utf8)
  var output = [UInt8](); output.reserveCapacity(bytes.count * 2)
  for byte in bytes { output.append(digits[Int(byte >> 4)]); output.append(digits[Int(byte & 0x0f)]) }
  return String(decoding: output, as: UTF8.self)
}

private func wasiEvidence(context: inout DeterministicContext) throws -> [String: JSONValue] {
  #if os(WASI)
    var firstClock: __wasi_timestamp_t = 0
    var secondClock: __wasi_timestamp_t = 0
    guard __wasi_clock_time_get(0, 1, &firstClock) == 0,
      __wasi_clock_time_get(0, 1, &secondClock) == 0
    else { throw HostwrightWASIProviderSDKError.handlerFailed }
    var firstRandom = [UInt8](repeating: 0, count: 16)
    var secondRandom = [UInt8](repeating: 0, count: 16)
    let firstStatus = firstRandom.withUnsafeMutableBytes { getentropy($0.baseAddress, $0.count) }
    let secondStatus = secondRandom.withUnsafeMutableBytes { getentropy($0.baseAddress, $0.count) }
    guard firstStatus == 0, secondStatus == 0 else {
      throw HostwrightWASIProviderSDKError.handlerFailed
    }
    return [
      "wasiClockFirst": .string(String(firstClock)),
      "wasiClockSecond": .string(String(secondClock)),
      "wasiRandomFirst": .string(hex(firstRandom)),
      "wasiRandomSecond": .string(hex(secondRandom)),
    ]
  #else
    return [
      "wasiClockFirst": .string(context.timestamp),
      "wasiClockSecond": .string(context.timestamp),
      "wasiRandomFirst": .string(String(context.nextRandomUInt64())),
      "wasiRandomSecond": .string(String(context.nextRandomUInt64())),
    ]
  #endif
}

let status = CommandRunner.run { invocation, context in
  let random = context.nextRandomUInt64()
  guard case .object(let input) = invocation.input, case .string(let scope)? = input["scope"] else {
    throw HostwrightWASIProviderSDKError.malformedInvocation
  }
  var evidence = try wasiEvidence(context: &context)
  evidence["input"] = invocation.input
  evidence["random"] = .string(String(random))
  evidence["scope"] = .string(scope)
  evidence["timestamp"] = .string(context.timestamp)
  return Result(
    invocationID: invocation.invocationID,
    actions: [ProposedAction(
      capability: invocation.capability,
      kind: "propose",
      payload: .object(evidence))],
    diagnostics: [SanitizedDiagnostic(code: "reference-ok", message: "provider completed")])
}
exit(status)
