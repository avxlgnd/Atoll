//
//  MessageContactResolver.swift
//  DynamicIsland
//
//  Turns a phone number / e-mail address from the Messages database into a contact name and photo.
//

import Contacts
import Foundation

final class MessageContactResolver {
    static let shared = MessageContactResolver()

    private let store = CNContactStore()
    private var cache: [String: (name: String?, photo: Data?)] = [:]
    private let lock = NSLock()

    func requestAccessIfNeeded() {
        guard CNContactStore.authorizationStatus(for: .contacts) == .notDetermined else { return }
        store.requestAccess(for: .contacts) { _, _ in }
    }

    private var canReadContacts: Bool {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        return status != .notDetermined && status != .denied && status != .restricted
    }

    func resolve(_ handle: String) -> (name: String?, photo: Data?) {
        lock.lock()
        if let cached = cache[handle] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard canReadContacts else { return (nil, nil) }

        let predicate: NSPredicate = handle.contains("@")
            ? CNContact.predicateForContacts(matchingEmailAddress: handle)
            : CNContact.predicateForContacts(matching: CNPhoneNumber(stringValue: handle))
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactThumbnailImageDataKey as CNKeyDescriptor
        ]

        var result: (name: String?, photo: Data?) = (nil, nil)
        if let contact = (try? store.unifiedContacts(matching: predicate, keysToFetch: keys))?.first {
            let full = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let name = full.isEmpty ? (contact.nickname.isEmpty ? nil : contact.nickname) : full
            result = (name, contact.thumbnailImageData)
        }

        lock.lock()
        cache[handle] = result
        lock.unlock()
        return result
    }
}
