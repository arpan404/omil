# App Store answers and their basis

The following answers describe the current iOS app and its user-owned Mac engine. Recheck them if hosting, analytics, payment, or third-party SDKs change.

## App privacy

Suggested App Store Connect answer: **Data Not Collected**. No tracking. No advertising identifier. No developer-operated dictation service. The developer does not receive audio, transcripts, dictionary entries, or pairing tokens from normal app use. The user may send their own data to their own Mac and keep it locally. User-initiated sharing goes to the chosen destination.

Apple defines collection in terms of off-device transmission that allows the developer or their partners to access data beyond servicing a real-time request. See [App privacy details](https://developer.apple.com/app-store/app-privacy-details/). Website hosting request information is described separately in the privacy policy. Public support requests contain only the information the user chooses to submit. If a developer-operated review engine or hosted service is later introduced, reassess these answers.

The app privacy manifests declare `NSPrivacyTracking = false`, no collected data types, and UserDefaults use. The app uses `CA92.1` for its own preferences and `1C8F.1` for the App Group. The Release keyboard uses only `1C8F.1`; its standard-defaults preview key is Debug-only. See [Apple's approved reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype).

## Export compliance

`ITSAppUsesNonExemptEncryption` is false. The iOS app uses Apple system facilities and has no bundled proprietary encryption implementation. Tailscale is a separately installed VPN, not an embedded SDK. Review this answer if encryption dependencies change. See [Apple's export guidance](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations).

## Age rating and content rights

Complete Apple's current questionnaire in App Store Connect. The app has no ads, multiplayer, social feed, unrestricted web browser, contests, gambling, purchases, or developer-provided mature content. Private user dictation is not a public content-sharing service. Select the appropriate answers to the current fields; Apple calculates the final rating. The app is not specifically made for children. Confirm that you have rights to the icon, screenshots, copy, and distributed code. Screenshots use fictional text; Geist is supplied with its SIL Open Font License.

## License, pricing, and territory

Use Apple's standard EULA unless you intentionally supply a custom agreement. The source is MIT-licensed. Suggested price is Free, with no in-app purchases or subscriptions, matching the current product. Choose territories, trader status, tax and agreement answers, and review contact details using the developer's actual account information; these cannot be inferred from app code.

A public privacy policy and working support URL are required. A dedicated terms page is supplied for clarity; it does not replace Apple's EULA. The pages must be live before submission. See [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/).
