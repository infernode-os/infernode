# Google Play listing — InferNode

Draft store-listing copy and submission notes. Review/edit before entering into
the Play Console. Character limits are Play's hard maximums.

---

## Restricted SMS permissions — RESOLVED

`SEND_SMS`, `RECEIVE_SMS`, and `READ_SMS` are in Google Play's restricted
"SMS and Call Log" permission group, allowed only for apps whose core purpose
is to be the device's default SMS handler. An agent/OS environment that texts
as a *feature* does not qualify, so uploads requesting them are rejected.

**Resolution:** these three permissions and `InfernodeSmsReceiver` are stripped
from the **release** build (what goes to Play) via the manifest overlay
`app/src/release/AndroidManifest.xml`. The **debug/dev build keeps SMS**, so the
feature remains available for development and sideload. `CALL_PHONE` is not in
a restricted group and is kept in all builds.

This means the Play AAB (`bundleRelease`) carries no SMS permissions — nothing
further to do for this policy. Just don't re-add SMS to the release variant.

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
