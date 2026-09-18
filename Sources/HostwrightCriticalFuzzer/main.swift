import Darwin
import Foundation
import HostwrightControlPlane
import HostwrightImport
import HostwrightManifest
import HostwrightReleaseQualification
import HostwrightRuntime

private enum CriticalFuzzTarget: String, CaseIterable {
  case manifestV3 = "manifest-v3"
  case composeImport = "compose-import"
  case controlStreamV21 = "control-stream-v2.1"
  case containerizationHelperV1 = "containerization-helper-v1"
  case appleContainerJSON = "apple-container-json"
  case releaseQualificationJSON = "release-qualification-json"

  func evaluate(_ data: Data) {
    switch self {
    case .manifestV3:
      guard data.count <= ManifestParser.maximumUTF8Bytes else { return }
      _ = try? ManifestParser.parse(String(decoding: data, as: UTF8.self))
    case .composeImport:
      guard data.count <= ManifestParser.maximumUTF8Bytes else { return }
      _ = HostwrightCompose.importDocument(String(decoding: data, as: UTF8.self))
    case .controlStreamV21:
      guard data.count <= ControlPlaneContract.maximumResponseOrFrameBytes,
        let frame = try? ControlStreamFrameContract.decode(data)
      else { return }
      _ = try? ControlStreamFrameContract.validate(frame, direction: .clientToServer)
      _ = try? ControlStreamFrameContract.validate(frame, direction: .serverToClient)
    case .containerizationHelperV1:
      guard
        data.count <= ContainerizationHelperProtocolV1.maximumPayloadBytes
          + ContainerizationHelperProtocolV1.frameHeaderBytes
      else { return }
      if let payload = try? ContainerizationHelperFraming.decodeSingleFrame(data) {
        _ = try? ContainerizationHelperCanonicalJSON.decodeError(from: payload)
      }
      _ = try? ContainerizationHelperCanonicalJSON.decodeError(from: data)
    case .appleContainerJSON:
      guard data.count <= AppleContainerImageListOutputParser.maximumBytes else { return }
      _ = try? AppleContainerImageListOutputParser.contains(
        "docker.io/library/alpine:latest",
        in: String(decoding: data, as: UTF8.self)
      )
    case .releaseQualificationJSON:
      let boundary: ReleaseQualificationParserBoundaryTarget =
        data.first.map { $0 & 1 == 0 } == true
        ? .qualificationContractJSON
        : .hostwrightEvidenceJSON
      _ = ReleaseQualificationParserBoundaryHarness.evaluate(data: data, target: boundary)
    }
  }
}

private typealias FuzzerCallback = @convention(c) (UnsafePointer<UInt8>?, Int) -> Int32
private typealias FuzzerDriver =
  @convention(c) (
    UnsafeMutablePointer<Int32>,
    UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>>,
    FuzzerCallback
  ) -> Int32

private let selectedTarget: CriticalFuzzTarget? = ProcessInfo.processInfo.environment[
  "HOSTWRIGHT_FUZZ_TARGET"
].flatMap(CriticalFuzzTarget.init(rawValue:))

private func evaluateInput(_ pointer: UnsafePointer<UInt8>?, _ size: Int) -> Int32 {
  guard let selectedTarget, let pointer, size >= 0 else { return 0 }
  selectedTarget.evaluate(Data(bytes: pointer, count: size))
  return 0
}

@main
private enum HostwrightCriticalFuzzerMain {
  static func main() {
    guard let selectedTarget else {
      let names = CriticalFuzzTarget.allCases.map(\.rawValue).joined(separator: ", ")
      FileHandle.standardError.write(
        Data("HOSTWRIGHT_FUZZ_TARGET must be one of: \(names)\n".utf8)
      )
      exit(EX_USAGE)
    }

    if let handle = dlopen(nil, RTLD_NOW),
      let symbol = dlsym(handle, "LLVMFuzzerRunDriver")
    {
      let driver = unsafeBitCast(symbol, to: FuzzerDriver.self)
      var argc = Int32(CommandLine.argc)
      var argv = CommandLine.unsafeArgv
      let status = withUnsafeMutablePointer(to: &argc) { argcPointer in
        withUnsafeMutablePointer(to: &argv) { argvPointer in
          driver(argcPointer, argvPointer, evaluateInput)
        }
      }
      exit(status)
    }

    let paths = CommandLine.arguments.dropFirst()
    guard !paths.isEmpty else {
      FileHandle.standardError.write(
        Data(
          "No libFuzzer runtime or corpus files were supplied for \(selectedTarget.rawValue).\n"
            .utf8)
      )
      exit(EX_USAGE)
    }
    do {
      for path in paths {
        selectedTarget.evaluate(try Data(contentsOf: URL(fileURLWithPath: path)))
      }
    } catch {
      FileHandle.standardError.write(Data("Corpus replay failed: \(error)\n".utf8))
      exit(EX_DATAERR)
    }
  }
}
