# InferNode — Privacy Policy

_Last updated: 2026-06-01_

> **Draft for review.** Replace `{{LEGAL_ENTITY}}` with the legal entity that
> owns the Google Play / App Store developer account (the macOS signing cert
> reads "Synectify, Pte Ltd"; confirm which entity publishes) and confirm the
> contact address before publishing. This document must be hosted at a public
> URL and that URL entered in the Play Console listing.

InferNode ("the app") is published by {{LEGAL_ENTITY}} ("we", "us"). This
policy explains what the app does with your information. The short version:
InferNode is a self-contained operating-system environment that runs on your
device. We do not operate servers that collect your data, we do not sell or
share your data, and the app contains no advertising or third-party analytics
SDKs.

## What the app processes, and where

InferNode processes data **on your device**. Some features send data to
network endpoints **that you configure** — we do not control or receive that
data.

| Data | Why | Where it goes |
|------|-----|----------------|
| **Prompts / text you enter for the AI agent** | To answer your requests | To the language-model endpoint **you configure** (e.g. a self-hosted server on your network, or a third-party API such as Anthropic or OpenAI if you supply its address and key). Governed by that provider's privacy terms. |
| **Microphone audio** | Voice input and dialing features, when you invoke them | Processed on-device; transmitted to a model/voice endpoint only if you have configured one and invoke a voice feature. Not recorded or retained by us. |
| **SMS messages (send/receive/read)** | So the agent can send and read text messages at your explicit direction | Handled on-device by Android's telephony system. Message content is only passed to a configured model endpoint if you direct the agent to act on it. |
| **Phone dialing** | To place a call when you ask the agent to dial | Handed to Android's telephony system on-device. We do not log call activity. |
| **Credentials / keys (LLM API keys, mount keys)** | To authenticate to services you configure | Stored locally in the app's encrypted keyring/secstore, optionally gated behind device biometrics. Never transmitted to us. |
| **Local network connections** | To reach an InferNode/LLM/9P service on your LAN | Direct device-to-service on your network. Does not pass through us. |

## What we do **not** do

- We do not collect, store, or transmit your data to servers operated by us.
- We do not sell or share your personal data with third parties.
- The app contains no advertising SDKs and no third-party analytics SDKs.
- We do not track you across apps or websites.

## Permissions

The app requests these Android permissions only for the features above, each
granted by you at runtime:

- **Microphone** (`RECORD_AUDIO`) — voice and dial audio.
- **Internet** (`INTERNET`) — to reach model/9P endpoints you configure.
- **Phone** (`CALL_PHONE`) — to place a call when you ask the agent to dial.
- **SMS** (`SEND_SMS`, `RECEIVE_SMS`, `READ_SMS`) — to send and read text
  messages at your direction.
- **Notifications** (`POST_NOTIFICATIONS`) and **foreground service** — to keep
  the background service alive with a visible notification.

You can revoke any permission in Android Settings; the dependent feature stops
working but the rest of the app continues.

## Children

InferNode is a developer/operator tool and is not directed to children.

## Data deletion

All app data lives on your device. Uninstalling the app, or clearing its
storage in Android Settings, removes it. Data you sent to a third-party model
provider is subject to that provider's deletion process.

## Changes

We may update this policy; the "Last updated" date above will change.

## Contact

Questions: {{CONTACT_EMAIL}}
