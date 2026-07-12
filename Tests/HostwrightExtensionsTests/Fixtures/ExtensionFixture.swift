import Darwin
import Foundation

guard CommandLine.arguments == [CommandLine.arguments[0], "hostwright-extension-handshake-v1"] else {
    exit(9)
}
guard ProcessInfo.processInfo.environment["HOSTWRIGHT_EXTENSION_TEST_SECRET"] == nil,
      FileManager.default.currentDirectoryPath == "/" else {
    exit(10)
}

let requestData = FileHandle.standardInput.readDataToEndOfFile()
guard let request = try? JSONSerialization.jsonObject(with: requestData) as? [String: Any],
      request["protocolVersion"] as? Int == 1,
      request["operation"] as? String == "handshake",
      let requestID = request["requestID"] as? String,
      let identifier = request["extensionIdentifier"] as? String,
      let declarationSHA256 = request["declarationSHA256"] as? String,
      request["capability"] as? String == "diagnosticsRead" else {
    exit(11)
}

if identifier.hasSuffix(".timeout") {
    Thread.sleep(forTimeInterval: 2)
    exit(0)
}
if identifier.hasSuffix(".overflow") {
    FileHandle.standardOutput.write(Data(repeating: 65, count: 128 * 1_024))
    exit(0)
}
if identifier.hasSuffix(".failure") {
    FileHandle.standardError.write(Data("token=fixture-secret-must-not-leak\n".utf8))
    exit(7)
}
if identifier.hasSuffix(".malformed") {
    FileHandle.standardOutput.write(Data("not-json\n".utf8))
    exit(0)
}
if identifier.hasSuffix(".duplicate") {
    let response = """
    {"protocolVersion":1,"protocolVersion":1,"requestID":"\(requestID)","extensionIdentifier":"\(identifier)","declarationSHA256":"\(declarationSHA256)","capability":"diagnosticsRead","status":"ready"}
    """
    FileHandle.standardOutput.write(Data(response.utf8))
    exit(0)
}

var response: [String: Any] = [
    "protocolVersion": 1,
    "requestID": requestID,
    "extensionIdentifier": identifier,
    "declarationSHA256": declarationSHA256,
    "capability": "diagnosticsRead",
    "status": "ready"
]
if identifier.hasSuffix(".mismatch") {
    response["extensionIdentifier"] = "dev.hostwright.integration.other"
}
if identifier.hasSuffix(".extra") {
    response["unexpected"] = "field"
}
if identifier.hasSuffix(".stderr") {
    FileHandle.standardError.write(Data("unexpected warning\n".utf8))
}

let responseData = try JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
FileHandle.standardOutput.write(responseData + Data("\n".utf8))
