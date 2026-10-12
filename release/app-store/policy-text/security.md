# Security

Updated October 11, 2026. Operator: Arpan Bhandari.

Your Mac runs the engine. You choose the network. Protect the connection as carefully as the words you dictate.

## Your Mac is the trust boundary

Pair only with a Mac you own or trust. A pairing QR code contains the connection address and a token that grants access to the speech engine. Treat that code and token as a secret.

Omil has no developer-hosted dictation endpoint. The engine processes the audio and text you send to the Mac you configured.

## Local network and Tailscale

The local Mac engine uses HTTP and a bearer token. The token authenticates requests but does not encrypt them. Use a trusted private network; do not port-forward the engine directly to the public internet.

For access away from home, connect your devices through Tailscale and use your Mac's tailnet address. Tailscale provides encryption and access controls outside Omil. Keep both devices signed into your intended tailnet and limit access to trusted devices.

The engine health endpoint is intentionally accessible without the token and can expose engine readiness. Protected engine actions require the token.

## Local storage and permissions

The mobile app stores dictation history in its own container using iOS file protection. The keyboard receives session results through an App Group, not access to your complete history. Pairing details are stored in app preferences; device access and backups should be protected.

The microphone can remain active while a keyboard session is enabled. iOS shows its microphone indicator, and you can turn the session off in Omil. Review permissions in iOS Settings at any time.

## Updates and safe setup

Install Mac releases from the Omil website or the official arpan404/omil GitHub repository. The Mac app checks a signed Sparkle update feed. Update the iPhone and iPad app through its authorized distribution channel.

Keep macOS, iOS, iPadOS, Tailscale, and Omil up to date. Use a passcode and the device protections provided by Apple.

## Reporting a problem

Use the Support page for non-sensitive bug reports. Describe the affected version and what you observed. Do not publish exploit details that would put other users at risk, dictation contents, credentials, or pairing tokens.

For a sensitive report, contact the developer through the linked GitHub profile to arrange a private channel before sending details.

Support: https://omil.arpan.sh/support/
Developer: https://github.com/arpan404
