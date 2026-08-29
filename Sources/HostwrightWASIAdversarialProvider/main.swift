import HostwrightWASIProviderSDK
#if os(WASI)
  import WASILibc
#else
  import Darwin
#endif

private func scenario(_ input: JSONValue) -> String? {
  guard case .object(let object) = input, case .string(let value)? = object["adversarial"] else {
    return nil
  }
  return value
}

let status = CommandRunner.run { invocation, _ in
  switch scenario(invocation.input) {
  case "wrong-capability":
    let other: Capability = invocation.capability == .network ? .policy : .network
    return Result(
      invocationID: invocation.invocationID,
      actions: [ProposedAction(capability: other, kind: "escape", payload: .object([:]))])
  case "oversize":
    #if os(WASI)
      let count = 64 * 1_024
      guard let storage = calloc(count, 1) else { abort() }
      defer { free(storage) }
      _ = memset(storage, 120, count)
      for _ in 0..<17 { _ = WASILibc.write(STDOUT_FILENO, storage, count) }
    #endif
    return Result(invocationID: invocation.invocationID)
  case "hang":
    while true {}
  case "crash":
    abort()
  case "ambient":
    #if os(WASI)
      let descriptor = open("/etc/passwd", O_RDONLY)
      if descriptor >= 0 { _ = close(descriptor) }
      let home = getenv("HOME")
      return Result(
        invocationID: invocation.invocationID,
        diagnostics: [SanitizedDiagnostic(
          code: "ambient-probe",
          message: descriptor < 0 && home == nil ? "denied" : "unexpected-access")])
    #else
      return Result(
        invocationID: invocation.invocationID,
        diagnostics: [SanitizedDiagnostic(code: "ambient-probe", message: "host-build")])
    #endif
  default:
    return Result(
      invocationID: invocation.invocationID,
      diagnostics: [SanitizedDiagnostic(code: "adversarial-idle", message: "no scenario")])
  }
}
exit(status)
