# Release readiness

This package contains the screenshots, editable source, English store text, review notes, privacy answers, and website policies for iPhone and iPad. It has not been uploaded or submitted to Apple.

## Completed

- Five iPhone PNGs, 1320 × 2868; five iPad PNGs, 2064 × 2752. All exports are opaque RGB PNGs. Apple's accepted sizes are documented in [screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/).
- Actual Omil simulator UI with fictional dictation; no personal transcripts or pairing tokens. Original captures are included separately from the headline layouts.
- Store name, subtitle, description, keywords, promotional text, release notes, copyright, TestFlight description, and feedback instructions. Field lengths are validated.
- Privacy, Security, Terms, and Support pages in the marketing site, with footer navigation and sitemap entries. Privacy/support/terms/security links are present in the mobile app.
- App and keyboard privacy manifests, plus the app export-compliance declaration.
- Signed Release archive for version 0.1.9, build 11, with matching app/keyboard versions. The archive is a local artifact under `.build/distribution/Omil-release.X0sWx7/OmilIOS.xcarchive`.

## Required before submission

1. **Apple distribution profiles.** The archive succeeded, but App Store IPA export failed with `Cloud signing permission error` and missing profiles for `sh.arpan.omil.ios` and `sh.arpan.omil.ios.keyboard`. The team API key can read both bundle IDs and the existing local Apple Distribution certificate, but profile creation returned HTTP 403. An export using the local certificate without the API key also reported `No Accounts`. A team administrator must permit profile creation for the key or install App Store profiles for both IDs using the existing distribution certificate and `group.sh.arpan.omil.shared`. Then rerun the export script. Do not upload the development archive as if it were a verified App Store IPA.
2. **Keyboard behavior.** [Guideline 4.4.1](https://developer.apple.com/app-store/review/guidelines/#extensions) prohibits keyboards from launching apps other than Settings and requires input functionality without Full Access. The current keyboard uses a responder-chain `UIApplication.open` call to open Omil and shows only a permission message without Full Access. Change the flow to start the microphone from the containing app, keep input controls and the next-keyboard control available in every permission state, and remove the responder-chain launcher. Alternatively, ship without the keyboard extension and remove its store claims. This package preserves the existing keyboard feature instead of silently removing it.
3. **Reviewer access to the Mac engine.** Provide a working way to test the Mac-dependent functions, clearly disclose hardware requirements, and arrange Apple's review access. The Debug screenshot fixtures are not present in the submitted Release app and must not be described as a review demo.
4. **App Store Connect app record.** The configured API key returned no app record for `sh.arpan.omil.ios`. Create the iOS app record using that bundle ID, English (U.S.) as the primary language, and a unique SKU. iPhone/iPad share one app record. Confirm the version and next unused build number before upload.
5. **Account information.** Supply actual review contact name, email, and phone; complete agreements, territory/trader status, pricing, availability, content rights, and age-rating questions. These are owner-provided account details, not values to invent.
6. **Live policy URLs.** Deploy the marketing changes and confirm that `/privacy/`, `/security/`, `/terms/`, and `/support/` return 200. Do not submit links to unpublished pages.
7. **Release validation.** After keyboard changes, rerun builds, verify exported signatures and privacy manifests, and test the final distribution build on physical iPhone and iPad. Current verification includes the earlier physical iPhone tailnet check and simulator captures in both size classes; it does not claim a physical iPad acceptance test.

The product currently has English-only mobile dictation. Mac Nepali support is not a mobile release claim. App previews are optional and no preview video is fabricated or required by this package.
