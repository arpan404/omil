export interface PolicyPageData { title: string; summary: string; sections: [string, string, string[]][]; }

export const policyUpdated = "October 11, 2026";

export const policies: Record<string, PolicyPageData> = {
  "privacy": {
    "title": "Privacy policy",
    "summary": "Your dictation belongs to you. Here is what Omil stores, what travels between your devices, and what you control.",
    "sections": [
      [
        "who",
        "Who operates Omil",
        [
          "Omil is developed by Arpan Bhandari. This policy covers the Omil Mac app, the iPhone and iPad app, and the Omil keyboard. Questions about this policy can be sent through the Support page."
        ]
      ],
      [
        "speech",
        "Where your speech goes",
        [
          "When you choose the Mac engine, Omil sends recorded audio and text to the Mac you pair with for speech recognition and cleanup. The models run on that Mac. Omil does not operate a hosted speech service.",
          "If you choose an available on-device Apple speech engine in Advanced settings, speech recognition uses Apple's on-device speech frameworks. System services may download speech assets. You can independently choose whether to send text to your Mac for cleanup."
        ]
      ],
      [
        "storage",
        "What stays on your devices",
        [
          "The iPhone and iPad app stores settings, dictionary entries, connection details, and up to 200 recent dictation transcripts in its own storage. The Mac app can also keep dictation history and recordings locally. Omil uses temporary audio while processing speech.",
          "The app and its keyboard share current session state, microphone status, theme choices, and dictation results through an App Group on your device. The keyboard cannot read the app's separate dictation history.",
          "Omil does not record the characters you type with other keyboards. The keyboard uses the surrounding text context supplied by iOS to insert a transcript with appropriate spacing."
        ]
      ],
      [
        "permissions",
        "Permissions are for specific actions",
        [
          "Microphone permission lets you record speech. Camera permission lets you scan a pairing QR code; Omil does not save or upload camera images. Local Network permission lets you reach the Mac engine. Speech Recognition permission is used for supported Apple speech engines.",
          "Keyboard Full Access allows communication between the keyboard and the Omil app. During a keyboard microphone session, the app keeps the microphone ready in the background until you turn it off or the selected session timer expires. Between dictations, audio is not saved or sent by Omil."
        ]
      ],
      [
        "network",
        "Network access and third parties",
        [
          "On a local network, the Mac connection uses HTTP authenticated with a pairing token. HTTP does not encrypt traffic by itself. Use a network you trust. If you use Tailscale, its VPN encrypts traffic between your devices; Tailscale is a separate service with its own terms and privacy policy.",
          "Omil may contact model download providers during Mac setup, and GitHub for Mac app updates. The website is served by Vercel and uses GitHub to retrieve release information. These providers may process ordinary request information such as IP addresses. Website hosting is separate from dictation processing.",
          "Omil has no advertising or third-party analytics SDK in its iOS app, and does not track you across apps or websites. The developer does not receive your dictation audio, transcripts, dictionary, or pairing token through a developer-operated service."
        ]
      ],
      [
        "control",
        "Deleting and sharing your data",
        [
          "You can delete individual transcripts or clear history from the History screen. Removing the app removes its app-local data, subject to device backups and Apple's storage behavior. Shared App Group data may remain while another member of the group is installed. Delete Mac history separately on your Mac.",
          "Copying or sharing a transcript gives it to the clipboard, destination app, or recipient you choose. Those destinations and any backups you enable have their own data-handling practices. Omil cannot delete copies you have shared elsewhere."
        ]
      ],
      [
        "contact",
        "Support and policy changes",
        [
          "If you send a support request, we receive what you choose to include. Do not include private dictation, pairing tokens, or credentials in a public issue.",
          "We will update this page when these practices change. The date above identifies the current version. Use the Support page to ask questions or request help."
        ]
      ]
    ]
  },
  "security": {
    "title": "Security",
    "summary": "Your Mac runs the engine. You choose the network. Protect the connection as carefully as the words you dictate.",
    "sections": [
      [
        "boundary",
        "Your Mac is the trust boundary",
        [
          "Pair only with a Mac you own or trust. A pairing QR code contains the connection address and a token that grants access to the speech engine. Treat that code and token as a secret.",
          "Omil has no developer-hosted dictation endpoint. The engine processes the audio and text you send to the Mac you configured."
        ]
      ],
      [
        "transport",
        "Local network and Tailscale",
        [
          "The local Mac engine uses HTTP and a bearer token. The token authenticates requests but does not encrypt them. Use a trusted private network; do not port-forward the engine directly to the public internet.",
          "For access away from home, connect your devices through Tailscale and use your Mac's tailnet address. Tailscale provides encryption and access controls outside Omil. Keep both devices signed into your intended tailnet and limit access to trusted devices.",
          "The engine health endpoint is intentionally accessible without the token and can expose engine readiness. Protected engine actions require the token."
        ]
      ],
      [
        "storage",
        "Local storage and permissions",
        [
          "The mobile app stores dictation history in its own container using iOS file protection. The keyboard receives session results through an App Group, not access to your complete history. Pairing details are stored in app preferences; device access and backups should be protected.",
          "The microphone can remain active while a keyboard session is enabled. iOS shows its microphone indicator, and you can turn the session off in Omil. Review permissions in iOS Settings at any time."
        ]
      ],
      [
        "updates",
        "Updates and safe setup",
        [
          "Install Mac releases from the Omil website or the official arpan404/omil GitHub repository. The Mac app checks a signed Sparkle update feed. Update the iPhone and iPad app through its authorized distribution channel.",
          "Keep macOS, iOS, iPadOS, Tailscale, and Omil up to date. Use a passcode and the device protections provided by Apple."
        ]
      ],
      [
        "report",
        "Reporting a problem",
        [
          "Use the Support page for non-sensitive bug reports. Describe the affected version and what you observed. Do not publish exploit details that would put other users at risk, dictation contents, credentials, or pairing tokens.",
          "For a sensitive report, contact the developer through the linked GitHub profile to arrange a private channel before sending details."
        ]
      ]
    ]
  },
  "terms": {
    "title": "Terms of use",
    "summary": "Omil is free software for your own dictation. These terms explain the requirements, licenses, and limits.",
    "sections": [
      [
        "scope",
        "Using Omil",
        [
          "Omil is developed by Arpan Bhandari. You are responsible for the devices, networks, and content you use with Omil. Use it lawfully and only record audio you are authorized to record.",
          "The iPhone and iPad app's Mac engine requires an Apple silicon Mac with macOS 14 or later, Omil installed on that Mac, and a working connection between your devices. Initial Mac model setup requires an internet connection and Homebrew. Mobile dictation is currently designed for English."
        ]
      ],
      [
        "license",
        "Software licenses",
        [
          "Omil's source code is available under the MIT License in its official GitHub repository. That license governs use, copying, modification, and distribution of the source code and retains its copyright and permission notices.",
          "For the App Store version, Apple's standard Licensed Application End User License Agreement applies unless a separate custom agreement is supplied in App Store Connect. Apple's terms apply to use of the App Store. Third-party libraries and model weights retain their own licenses."
        ]
      ],
      [
        "cost",
        "Price and third-party services",
        [
          "Omil currently has no account requirement, advertising, subscription, or in-app purchases. You provide your own Mac and network.",
          "Apple, your network provider, GitHub, model download providers, and optional Tailscale have their own terms. Omil does not operate those services or guarantee their availability."
        ]
      ],
      [
        "accuracy",
        "Review your dictation",
        [
          "Speech recognition and cleanup can make mistakes or change wording. Check the transcript before sending it or relying on it. Omil lets you compare original and cleaned text, but cannot guarantee accuracy.",
          "Omil is not a substitute for professional judgment where transcription errors could cause harm."
        ]
      ],
      [
        "warranty",
        "Availability and warranty",
        [
          "To the extent allowed by applicable law, Omil is provided as is, without warranties, as described in the MIT License. Nothing in these terms limits rights that cannot lawfully be limited.",
          "Features, supported systems, and model availability may change. These terms do not promise a particular service level or ongoing availability of third-party services."
        ]
      ],
      [
        "contact",
        "Questions and changes",
        [
          "See the Privacy policy for data handling and the Support page for questions. We will update this page when these terms change, with the date shown above."
        ]
      ]
    ]
  },
  "support": {
    "title": "Help and support",
    "summary": "Get connected, keep the microphone under your control, and get your words where you need them.",
    "sections": [
      [
        "start",
        "Start with your Mac",
        [
          "Download Omil for Mac from the home page and install it in Applications. Open Omil, finish model setup, and grant the requested permissions. In Engine, enable sharing and choose Pair iPhone.",
          "On iPhone or iPad, open Omil and scan the pairing code. If your device cannot scan codes, enter the host, port, and token shown by your Mac. Never share the token in a public support request."
        ]
      ],
      [
        "connection",
        "If your Mac is unreachable",
        [
          "Keep Omil running on your Mac and check that its engine is ready. Confirm the devices can reach each other on the local network and that Local Network permission is enabled for Omil.",
          "For Tailscale, connect both devices to the intended tailnet. In Omil, use the Mac's 100.x.x.x tailnet address, the engine's port, and the pairing token. A local Wi-Fi address may not work when you leave that network. Check the Security page before exposing any engine endpoint."
        ]
      ],
      [
        "keyboard",
        "Using the Omil keyboard",
        [
          "Add Omil under iOS Settings, General, Keyboard, Keyboards. Full Access lets the keyboard communicate with the Omil app; it does not send your typing to the developer.",
          "If a microphone session has ended, return to Omil to start it again. Use Turn Off Keyboard Mic Now in Omil settings to stop the background session. Some apps and secure text fields do not allow third-party keyboards."
        ]
      ],
      [
        "history",
        "History, language, and requirements",
        [
          "Recent dictations stay on this device. Open History to search, delete an entry, or clear history. You can compare cleaned text with the original before copying it.",
          "The iPhone and iPad app requires iOS or iPadOS 17 or later and is designed for English. The Mac app also supports Nepali; mobile Nepali support is not included in this release. The Mac engine requires an Apple silicon Mac with macOS 14 or later."
        ]
      ],
      [
        "report",
        "Send a bug report",
        [
          "Open an issue in the official GitHub repository. Include your Omil version, iOS or iPadOS version, device model, and steps that reproduce the problem. Say whether you are using local Wi-Fi or Tailscale.",
          "Use fictional dictation in examples. Remove tokens, credentials, personal text, and other sensitive information from screenshots and logs. Public issues are visible to everyone."
        ]
      ]
    ]
  }
};
