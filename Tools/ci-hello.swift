// Test fixture only. The independently maintained example lives in notch-extension-hello.
import Foundation
while let line = readLine(), let bytes = line.data(using:.utf8) {
    guard bytes.count < 65536, let request = try? JSONSerialization.jsonObject(with:bytes) as? [String:Any],
          request["type"] as? String == "hello", let id = request["requestID"] as? String else { break }
    let response:[String:Any] = ["type":"hello","protocolVersion":1,"requestID":id,"message":"Hello Notch","title":"Hello Notch","subtitle":"Native CI fixture","progress":0.65]
    guard let output = try? JSONSerialization.data(withJSONObject:response) else { break }
    FileHandle.standardOutput.write(output);FileHandle.standardOutput.write(Data([10]))
}
