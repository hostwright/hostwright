import Darwin
import Foundation

do {
  let command = try ControlSecurityQualificationCommand.parse(
    Array(CommandLine.arguments.dropFirst())
  )
  if let result = try ControlSecurityQualificationRunner.run(command) {
    FileHandle.standardOutput.write(result)
    FileHandle.standardOutput.write(Data("\n".utf8))
  }
  exit(0)
} catch {
  let reason = (error as? ControlSecurityQualificationError)?.rawValue ?? "internalFailure"
  FileHandle.standardError.write(
    Data("phase09 gate2 live qualification failed: \(reason)\n".utf8)
  )
  exit(70)
}
