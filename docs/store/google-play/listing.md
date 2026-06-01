# Google Play listing — InferNode

Draft store-listing copy and submission notes. Review/edit before entering into
the Play Console. Character limits are Play's hard maximums.

---

## ⚠️ BLOCKER: restricted SMS permissions

The app's manifest declares `SEND_SMS`, `RECEIVE_SMS`, and `READ_SMS`. These
are in Google Play's **restricted permission groups** (the "SMS and Call Log"
policy). Google Play **only permits these for apps whose core, user-facing
purpose is to be the device's default SMS handler** (or a short list of other
eligible cases). An agent/OS environment that sends texts as a *feature* does
not qualify, and uploads that request these permissions without an approved
declaration are **rejected during review**.

This must be resolved before the first Play upload. Options, roughly in order
of least disruption:

1. **Ship the Play build without SMS.** Remove the three SMS permissions, the
   `InfernodeSmsReceiver`, and gate the SMS feature off for the Play flavor
   (e.g. a `play` product flavor that excludes them). The agent's SMS slice is
   then unavailable on Play-distributed installs only. **Recommended** — keeps
   the app shippable and the SMS feature available in sideloaded/APK builds.
2. **Apply for a Play policy exception** via the Permissions Declaration Form.
   Eligibility is narrow; an agent use case is unlikely to be approved.
3. **Become the default SMS handler.** Requires implementing the full default-
   SMS-app contract and reframing the app's primary purpose. Not appropriate
   here.

`CALL_PHONE` is **not** in the restricted Call Log group and is fine to keep
(runtime permission). Only the SMS trio is the blocker.

See `docs/store/google-play/READINESS.md` for the full checklist.

---

## Title (≤30 chars)

InferNode

## Short description (≤80 chars)

Inferno OS for the AI age: a namespace agent environment for your phone.

## Full description (≤4000 chars)

InferNode is a 64-bit build of the Inferno® distributed operating system —
originally developed at Bell Labs — packaged to run as an app on your device.

It is a self-contained computing environment, not a thin client. The whole
runtime lives on your phone: a graphical shell (Lucifer), a concurrent
programming runtime (Dis), and a namespace model in which everything —
devices, services, even remote machines — is a file you can mount and compose.

Highlights:

• Namespace-based agent environment. The Veltro agent operates over a 9P
  filesystem interface, so its tools and capabilities are mountable files you
  can inspect and control.

• Bring your own model. Connect the agent to a language-model endpoint you
  choose — a server on your own network, or a third-party API you configure.
  Your keys are stored in an on-device encrypted keyring, optionally unlocked
  with biometrics.

• 9P networking. Mount remote InferNode services over your LAN or VPN and treat
  them as local files.

• Voice and telephony features. Optional microphone, dialing, and (on supported
  distributions) messaging integration, each gated behind a permission you
  grant explicitly.

• Private by design. There is no advertising, no third-party analytics, and no
  developer-operated server collecting your data. Everything runs locally except
  the endpoints you point it at.

InferNode is aimed at developers, operators, and the technically curious. It
assumes familiarity with command-line and operating-system concepts.

Inferno® is a trademark of Vita Nuova®. InferNode is an independent build and
is not affiliated with or endorsed by the trademark owner.

## Category

Tools

## Tags / keywords (guidance)

operating system, developer tools, agent, terminal, 9P, Inferno

## Contact

- Email: {{CONTACT_EMAIL}}
- Privacy policy URL: {{PRIVACY_POLICY_URL}}  ← host docs/store/PRIVACY.md

---

## Content rating (IARC questionnaire)

You complete this in the Console. The app has no violent/sexual/gambling
content; the honest answers point to an "Everyone / PEGI 3" outcome. Note: the
app does provide unrestricted user-controlled computing and network access —
answer the "user-generated content / unrestricted internet" items truthfully.

## Data safety form (guidance — you submit the final answers)

Play's Data Safety form asks what data is *collected* (sent off the device) and
*shared*. InferNode itself operates no collection backend, but data you direct
to a configured model endpoint counts as collected/shared **by the app** for
form purposes. Suggested answers, assuming the SMS blocker is resolved by
removing SMS from the Play build:

- **Does your app collect or share user data?** Yes (conditionally — only data
  the user sends to a model endpoint they configure).
- **Messages / audio / app activity** sent to a configured model endpoint:
  mark as collected, purpose "App functionality", transmitted off-device,
  not sold, optionally encrypted in transit (depends on the endpoint).
- **No** advertising or third-party analytics data types.
- **Data is not used for tracking** across apps/sites.

Be conservative and accurate; mismatches between this form and observed
behavior are a common rejection cause.
