import CryptoKit
import Darwin
import Foundation
import HostwrightControlPlane
import HostwrightWASIProviderRuntime

private func fail(_ token: String, status: Int32 = 70) -> Never {
  FileHandle.standardError.write(Data("hostwright-wasi-provider-worker: \(token)\n".utf8))
  exit(status)
}

private func value(_ name: String, arguments: [String]) -> String? {
  guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
  return arguments[index + 1]
}

private let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--version"] {
  print("hostwright-plugin-abi-v1-wasi-preview1")
  exit(0)
}
guard arguments.count == 12,
  let modulePath = value("--module", arguments: arguments),
  let expectedDigest = value("--digest", arguments: arguments),
  let secondsText = value("--wall-seconds", arguments: arguments),
  let nanosecondsText = value("--wall-nanoseconds", arguments: arguments),
  let seedText = value("--seed", arguments: arguments),
  let pagesText = value("--memory-pages", arguments: arguments),
  let wallSeconds = UInt64(secondsText), let wallNanoseconds = UInt32(nanosecondsText),
  let seed = UInt64(seedText), let maximumMemoryPages = UInt64(pagesText),
  expectedDigest.range(of: "^sha256:[a-f0-9]{64}$", options: .regularExpression) != nil
else { fail("invalid-request", status: 64) }

private let workerResidentCeiling = UInt64(512 * 1_024 * 1_024)

private func startResidentMemoryWatchdog() -> Bool {
  var initial = rusage()
  guard getrusage(RUSAGE_SELF, &initial) == 0,
    UInt64(initial.ru_maxrss) <= workerResidentCeiling
  else { return false }
  Thread.detachNewThread {
    while true {
      var usage = rusage()
      guard getrusage(RUSAGE_SELF, &usage) == 0,
        UInt64(usage.ru_maxrss) <= workerResidentCeiling
      else { _exit(70) }
      usleep(10_000)
    }
  }
  return true
}

guard startResidentMemoryWatchdog() else { fail("containment-failed") }

var info = stat()
guard modulePath.hasPrefix("/"), !modulePath.contains("\0"),
  lstat(modulePath, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
  info.st_uid == getuid(), (info.st_mode & 0o022) == 0,
  info.st_size > 0, info.st_size <= WASILimits.default.moduleBytes
else { fail("module-rejected", status: 65) }

do {
  let module = try Data(contentsOf: URL(fileURLWithPath: modulePath), options: [.mappedIfSafe])
  guard module.count == Int(info.st_size), module.count <= WASILimits.default.moduleBytes else {
    fail("module-rejected", status: 65)
  }
  let digest = "sha256:" + SHA256.hash(data: module).map { String(format: "%02x", $0) }.joined()
  guard digest == expectedDigest else { fail("module-rejected", status: 65) }
  let status = try WASIProviderModuleRuntime.run(
    moduleBytes: module, wallSeconds: wallSeconds, wallNanoseconds: wallNanoseconds,
    seed: seed, maximumMemoryPages: maximumMemoryPages)
  exit(Int32(bitPattern: status))
} catch {
  fail("execution-failed")
}
