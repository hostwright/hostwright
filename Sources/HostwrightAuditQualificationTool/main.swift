import Darwin
import Foundation

do {
  let command = try AuditQualificationCommand.parse(Array(CommandLine.arguments.dropFirst()))
  let result = try AuditQualificationRunner.run(command)
  FileHandle.standardOutput.write(result)
  FileHandle.standardOutput.write(Data("\n".utf8))
  exit(0)
} catch {
  let reason = (error as? AuditQualificationError)?.rawValue ?? "internalFailure"
  FileHandle.standardError.write(Data("phase09 gate4 live qualification failed: \(reason)\n".utf8))
  exit(70)
}
