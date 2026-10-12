# Help and support

Updated October 11, 2026. Operator: Arpan Bhandari.

Get connected, keep the microphone under your control, and get your words where you need them.

## Start with your Mac

Download Omil for Mac from the home page and install it in Applications. Open Omil, finish model setup, and grant the requested permissions. In Engine, enable sharing and choose Pair iPhone.

On iPhone or iPad, open Omil and scan the pairing code. If your device cannot scan codes, enter the host, port, and token shown by your Mac. Never share the token in a public support request.

## If your Mac is unreachable

Keep Omil running on your Mac and check that its engine is ready. Confirm the devices can reach each other on the local network and that Local Network permission is enabled for Omil.

For Tailscale, connect both devices to the intended tailnet. In Omil, use the Mac's 100.x.x.x tailnet address, the engine's port, and the pairing token. A local Wi-Fi address may not work when you leave that network. Check the Security page before exposing any engine endpoint.

## Using the Omil keyboard

Add Omil under iOS Settings, General, Keyboard, Keyboards. Full Access lets the keyboard communicate with the Omil app; it does not send your typing to the developer.

If a microphone session has ended, return to Omil to start it again. Use Turn Off Keyboard Mic Now in Omil settings to stop the background session. Some apps and secure text fields do not allow third-party keyboards.

## History, language, and requirements

Recent dictations stay on this device. Open History to search, delete an entry, or clear history. You can compare cleaned text with the original before copying it.

The iPhone and iPad app requires iOS or iPadOS 17 or later and is designed for English. The Mac app also supports Nepali; mobile Nepali support is not included in this release. The Mac engine requires an Apple silicon Mac with macOS 14 or later.

## Send a bug report

Open an issue in the official GitHub repository. Include your Omil version, iOS or iPadOS version, device model, and steps that reproduce the problem. Say whether you are using local Wi-Fi or Tailscale.

Use fictional dictation in examples. Remove tokens, credentials, personal text, and other sensitive information from screenshots and logs. Public issues are visible to everyone.

Support: https://omil.arpan.sh/support/
Developer: https://github.com/arpan404
