# InferNode — Support

> **Draft for review.** Confirm the contact address and any issue-tracker URL
> you want public before hosting. Google Play requires a support contact (email
> at minimum); a public support URL is recommended.

## Getting help

- **Email:** {{CONTACT_EMAIL}}
- **Issues / bug reports:** https://github.com/infernode-os/infernode/issues
- **Documentation:** https://github.com/infernode-os/infernode (see `README.md`,
  `QUICKSTART.md`, and `docs/`)

## What InferNode is

InferNode is a 64-bit build of the Inferno® distributed operating system,
packaged to run on your device. It hosts a namespace-based agent environment,
a graphical shell (Lucifer), and tools for connecting to language-model and
9P services that you configure.

## Common questions

**The agent can't reach my model.** Check that the endpoint address and key are
set correctly in Settings and that the device can reach the host (same network /
VPN). Local-network features require granting the local-network permission.

**Voice/dial/SMS does nothing.** These features need their respective runtime
permissions (microphone, phone, SMS). Grant them when prompted, or in Android
Settings → Apps → InferNode → Permissions.

**How do I remove my data?** Everything is on-device. Uninstall the app or clear
its storage in Android Settings.

## Reporting a security issue

Please do not file public issues for security vulnerabilities. Email
{{CONTACT_EMAIL}} with details and we will respond.
