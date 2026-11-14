import Foundation
import Testing

@testable import OsaurusCore

struct PrimitiveJSONSerializationTests {
    @Test(arguments: ["null", "true", "5", #""hello""#, "[]", #"{"value":null}"#])
    func messageHelperResultsPreserveAllJSONValues(value: String) throws {
        let line = Data("{\"id\":1,\"result\":\(value)}".utf8)
        let imessage = try #require(IMessageRPCFraming.parseResponseLine(line)?.resultJSON)
        let whatsapp = try #require(WhatsAppRPCFraming.parseResponseLine(line)?.resultJSON)
        #expect(String(decoding: imessage, as: UTF8.self) == value)
        #expect(String(decoding: whatsapp, as: UTF8.self) == value)
    }

    @Test(arguments: ["null", "true", "5", #""hello""#, "[]", #"{"value":null}"#])
    func malformedNotificationParamsDoNotCrashBeforeTypedDecoding(value: String) throws {
        let line = Data("{\"method\":\"message\",\"params\":\(value)}".utf8)
        let imessage = try #require(IMessageRPCFraming.parseNotificationLine(line))
        let whatsapp = try #require(WhatsAppRPCFraming.parseNotificationLine(line))
        #expect(String(decoding: imessage.paramsJSON, as: UTF8.self) == value)
        #expect(String(decoding: whatsapp.paramsJSON, as: UTF8.self) == value)
    }

    @Test func sandboxNullParameterIsEncodedWithoutCrashing() {
        let spec = SandboxToolSpec(id: "probe", description: "probe", run: "true")
        let tool = SandboxPluginTool(spec: spec, plugin: SandboxPlugin(name: "probe", description: "probe"))
        let env = tool.buildParamVars(from: ["optional": NSNull(), "nested": ["value": NSNull()]])
        #expect(env["PARAM_OPTIONAL"] == "null")
        #expect(env["PARAM_NESTED"] == #"{"value":null}"#)
    }
}
