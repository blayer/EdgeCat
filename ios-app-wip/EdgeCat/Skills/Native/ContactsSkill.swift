import Foundation
import Contacts

// 1:1 functional port of android-app/assets/skills/read-contacts. CNContactStore
// requires the user to grant access on first call (Info.plist already has
// NSContactsUsageDescription). args: query=<substring> (optional).

public final class ContactsSkill: Skill, @unchecked Sendable {
    public var name: String { "read-contacts" }
    public var description: String { "Search the user's address book by name. arg: query (optional)" }
    public init() {}

    public func run(args: [String: String]) async -> ToolExecutionResult {
        let store = CNContactStore()
        let granted: Bool = await withCheckedContinuation { cont in
            store.requestAccess(for: .contacts) { ok, _ in cont.resume(returning: ok) }
        }
        guard granted else {
            return ToolExecutionResult(success: false, error: "contacts access denied")
        }
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey, CNContactFamilyNameKey, CNContactPhoneNumbersKey,
        ].map { $0 as CNKeyDescriptor }

        let needle = (args["query"] ?? "").lowercased()
        let request = CNContactFetchRequest(keysToFetch: keys)
        var results: [String] = []
        do {
            try store.enumerateContacts(with: request) { contact, _ in
                let name = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespaces)
                if !needle.isEmpty && !name.lowercased().contains(needle) { return }
                let phones = contact.phoneNumbers.compactMap { $0.value.stringValue }.joined(separator: ", ")
                results.append("\(name) — \(phones)")
                if results.count >= 25 { return }
            }
        } catch {
            return ToolExecutionResult(success: false, error: "\(error)")
        }
        return ToolExecutionResult(success: true,
                                   output: results.isEmpty ? "no matches" : results.joined(separator: "\n"))
    }
}
