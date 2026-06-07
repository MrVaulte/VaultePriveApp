//
//  VaultePrivacyPolicyCopy.swift
//  Vaulté Privé
//

import Foundation

enum VaultePrivacyPolicyCopy {
    static let documentTitle = "Privacy Policy"
    static let lastUpdated = "May 24, 2026"

    struct Section: Identifiable {
        let id: String
        let title: String
        let body: String
    }

    static let intro = """
    Vaulté Privé is a messenger. Your messages are encrypted on the phone before they go anywhere. \
    A relay server helps deliver them, but it is not built to read what you send.
    """

    static let sections: [Section] = [
        Section(
            id: "account",
            title: "Account",
            body: """
            When you register, you choose a username and can add a display name and photo. \
            That profile info is stored on the relay so other people can find you. \
            Your login details and encryption keys stay on the device — in the Keychain and local database.
            """
        ),
        Section(
            id: "messages",
            title: "Messages",
            body: """
            Text and photos are encrypted on your phone before sending. The relay only sees encrypted data, not the content.

            One Time Pad (Elite): you and your contact exchange pad files outside the app — AirDrop, Files, whatever works. \
            Pads stay on your devices. We do not upload them.

            Groups use the same encryption. Chat titles and membership sync through encrypted system messages.

            Disappearing messages (Elite): you pick a timer, new messages delete themselves. Your contact gets the same rule.

            Screenshot and copy alerts (Elite): if someone screenshots or asks to copy text, the app can warn the other person. \
            That happens inside the chat — not through any ad or analytics service.
            """
        ),
        Section(
            id: "calls",
            title: "Calls",
            body: """
            Calls use the microphone on your device. Audio is encrypted before it leaves the phone. \
            The relay knows who is calling and when, but not what was said.
            """
        ),
        Section(
            id: "premium",
            title: "Search, backup, subscriptions",
            body: """
            Local search (Premier / Elite) runs only on your phone. Search queries are not sent to the server.

            Encrypted backup exports a file you protect with your own passphrase. We do not know that passphrase and do not store it.

            Subscriptions are billed through Apple. We receive whether your plan is active — not your card number.
            """
        ),
        Section(
            id: "relay",
            title: "What the relay sees",
            body: """
            User IDs, conversation IDs, timestamps, encrypted message payloads, profile fields you uploaded, \
            and call signaling while a call is active.

            If encryption works as intended, the relay should not see message text or pad contents.
            """
        ),
        Section(
            id: "not",
            title: "What we do not do",
            body: """
            We do not sell your data. We do not run ads. We do not upload One Time Pad files. \
            We do not keep your backup passphrase. This version of the app has no built-in analytics or crash tracker.
            """
        ),
        Section(
            id: "delete",
            title: "Deletion",
            body: """
            You can delete chats in the app — including on both sides when the other person supports it. \
            Removing the app clears local data from your phone. Messages already on the relay are removed on their own schedule.
            """
        ),
        Section(
            id: "contact",
            title: "Contact",
            body: "Questions about privacy: privacy@vaulteprive.com"
        ),
    ]
}
