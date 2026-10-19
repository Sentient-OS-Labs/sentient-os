// Compile alongside Invitations/InviteCloud.swift and Mail Accounts/MailAccount.swift; no network or Keychain access.
// Verifies that only an explicit confirmation for the submitted code can reveal a gift.
import Foundation

@main struct Checks {
    static func main() throws {
        func response(_ confirmation: String? = nil, granted: Bool = true) throws -> Data {
            var value: [String: Any] = ["code": NSNull(), "campaignActive": false, "endsAt": NSNull(),
                "redeemedAt": granted ? 1234.0 : NSNull(), "redemptionCount": 0]
            if let confirmation { value["validatedCode"] = confirmation }
            return try JSONSerialization.data(withJSONObject: value)
        }
        func rejected(_ data: Data, code: String) {
            do {
                _ = try InviteCloud.verifiedSnapshot(from: data, redeeming: code)
                fatalError("Unverified response accepted")
            } catch InviteCloud.Failure.response {} catch { fatalError("Unexpected failure") }
        }
        rejected(try response(), code: "random thing")
        rejected(try response(), code: "WAITLIST_OGs")
        rejected(try response("WAITLIST_OGS"), code: "random thing")
        rejected(try response("MACAPPS_1000"), code: "FINAL_1000")
        rejected(try response("FINAL_1000", granted: false), code: "FINAL_1000")
        rejected(try response("FINAL_1000"), code: "FINAL_1000") // A lifetime receipt is not a late-use acknowledgement.
        for code in ["WAITLIST_OGs", "MACAPPS_1000", "A2B3C4", "A2B-3C4", "ABCDEF01-23456789", "Registered Custom Invite!"] {
            let result = try InviteCloud.verifiedSnapshot(from: response(code.uppercased()), redeeming: " \(code.lowercased())\n")
            precondition(result.hasLifetimeAccess)
        }
        let restored = try InviteCloud.verifiedSnapshot(from: response(), redeeming: nil)
        precondition(restored.hasLifetimeAccess)
        var late: [String: Any] = ["code": NSNull(), "campaignActive": false, "endsAt": NSNull(),
            "redeemedAt": NSNull(), "redemptionCount": 0, "validatedCode": "FINAL_1000",
            "lateUse": ["code": "FINAL_1000", "recordedAt": 1234.0, "email": "gift@example.invalid"]]
        let receipt = try InviteCloud.verifiedSnapshot(from: JSONSerialization.data(withJSONObject: late), redeeming: " final_1000 ")
        precondition(!receipt.hasLifetimeAccess && receipt.hasRecordedGift && receipt.showsLateGift)
        let cached = try JSONDecoder().decode(InviteSnapshot.self, from: JSONEncoder().encode(receipt))
        precondition(cached == receipt && cached.lateUse?.email == "gift@example.invalid", "Keychain snapshot round-trip must preserve late use and email")
        late["redeemedAt"] = 999.0
        let grandfathered = try InviteCloud.verifiedSnapshot(from: JSONSerialization.data(withJSONObject: late), redeeming: "FINAL_1000")
        precondition(grandfathered.hasLifetimeAccess && !grandfathered.showsLateGift && grandfathered.lateUse != nil)
        for invalid in [
            ["code": "MACAPPS_1000", "recordedAt": 1234.0, "email": "gift@example.invalid"] as [String: Any],
            ["code": "FINAL_1000", "recordedAt": 0, "email": "gift@example.invalid"],
            ["code": "FINAL_1000", "recordedAt": 1234.0, "email": "invalid"]
        ] {
            late["lateUse"] = invalid
            rejected(try JSONSerialization.data(withJSONObject: late), code: "FINAL_1000")
        }
        print("PASS: separate late-use receipt, email validation, Keychain encoding, and preservation of existing lifetime access")
        print("PASS: legacy saved receipts cannot validate codes; mismatched confirmations rejected; verified founder, generated, legacy and registered custom codes accepted; status restore preserved")
    }
}
