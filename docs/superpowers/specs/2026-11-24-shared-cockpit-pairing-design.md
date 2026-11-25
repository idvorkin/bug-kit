# Shared Cockpit pairing across Igor's apps (design proposal, #144)

Status: decided. Igor picked C on 2026-11-24: per-app keys plus a shared device identity, one approval tap per device.
BugKit builds the app side; Larry builds the keyring side ('approve every pending request from this device',
'revoke device').

## Summary

Igor, 2026-11-24: "do we have some kind of shared component so we can share our login key across all of the apps we
have installed? We also need a login key to talk to the Cockpit, the same way we do it with Stack Trainer."

Each of Igor's apps that talks to the Cockpit (Context Grabber, Think a Card / Stack Trainer, Exercise Analyzer, and
the board) pairs on its own today, two different ways, and one of them needs a code Igor can't get himself
(context-grabber #1356). This proposal gives every app the same pairing: tap "Pair with the Cockpit", approve a card
in the Inbox, done. Pairing once per device should be enough for every app where that's safe.

## Goals

- One way to pair, the same in every app: the approve-card flow the Cockpit's keyring already offers.
- Igor never needs a code from anyone: the app asks, a card appears, he approves.
- When a key lapses (7 idle days, 90 days max) the app re-asks on its own and says so, instead of failing with a 401.
- A lost or retired device, or one misbehaving app, can be cut off without re-pairing everything else.

## Non-goals

- No new server work beyond what keyring has (`/pair/start`, `/pair/poll`, approve in the Inbox).
- Not a login for anyone but Igor; not shared with other people's devices.
- Not the web: browser sessions keep their own login.

## How pairing works, from Igor's side

1. In any app: **Pair with the Cockpit**. The app shows "Waiting for you to approve on the Cockpit… code 4F2K".
2. The Inbox shows a card: "Pair Exercise Analyzer on iPhone 17 Pro? Code 4F2K". Igor checks the code matches and
   approves.
3. The app shows "Paired" within a few seconds and works.
4. Later, if the key lapses, the app shows "Your Cockpit pairing expired, approve again?" and starts step 1 itself.
5. The old one-time-code flow stays as a fallback for a device that can't reach the Inbox.

## The open question: one key per app, or one shared key

| | A. One key per app (Igor's 11/22 decision) | B. One shared key per device | C. Per-app keys, shared device identity |
|---|---|---|---|
| Approvals per new device | One per app (4 cards) | One | One per app, but each card is pre-filled and approving can cover "all my apps on this device" |
| Cut off one app | Yes, alone | No: revoking cuts every app | Yes, alone |
| Lost device | Revoke each app's key (or "revoke device" does it) | One revoke | One "revoke device" revokes all its keys |
| Scopes (what each app may do) | Each app asks only for its own | The key carries every app's scopes | Each app asks only for its own |
| Needs shared keychain across apps | No | Yes (same team, a shared keychain group) | Yes, for the device identity only |
| Server change | None | None | Small: an "approve all pending for this device" button, and "revoke device" |

## Decision

**C (Igor, 2026-11-24).** Keep one key per app, so each app holds only its own scopes and can be revoked alone, which was Igor's 11/22
reason. Share what's harmless to share: the device's identity (its label and the Cockpit's address) in a keychain
group all of Igor's apps can read, so the second app on a device needs nothing typed. Ask keyring for one small
addition, "approve every pending request from this device" on the card, so a new phone is one tap even with four
apps. (B, one shared key, was the simpler fallback; not chosen.)

## What each app sends to the keyring

So the two sides match, the pairing request every app sends (on top of keyring's existing approve-card request of app,
device and scopes) is:

| Field | What it is | Example |
|---|---|---|
| `app` | Which app is asking, a stable short name | `exercise-analyzer` |
| `app_label` | The app's name as Igor sees it on the card | `Exercise Analyzer` |
| `device_id` | The shared device identity: one random id per device, made by the first of Igor's apps to pair and read by the rest; it never changes for that device | a UUID |
| `device` | The device's label, also shared, editable by Igor | `Igor's iPhone 17 Pro` |
| `platform` | `iOS`, `iPadOS`, `macOS` or `watchOS` | `iOS` |
| `scopes` | Only the scopes this app needs | `["workout"]` |
| `app_version` | The app's build, for the card and for debugging | `2.0.0 (3675)` |

The answer is keyring's existing one (a 4-letter code to match on the card, a handle to poll, and when the request
lapses). The card groups pending requests by `device_id`, which is what "approve every pending request from this
device" approves, and "revoke device" revokes every key issued to that `device_id`.

## What's shared, and where

- **BugKit owns** the pairing flow (start, wait, poll, store, re-pair on expiry), its screen and its copyable errors,
  and the shared device identity. Every app already embeds BugKit, so no new dependency.
- **Each app owns** its own key, the scopes it asks for, and where its "Pair" button sits.
- **Storage:** each key in the app's own keychain; the device identity in a keychain group shared by Igor's apps,
  which requires them all to be signed by the same team (they are). It is the group the link flow already shares, so
  Context Grabber and Think a Card need no new entitlement.

## Details the app side settles

- **The device's first name.** The first app to pair names the device after its model and the first four characters
  of its id, as `iPhone18,1 7F3A`. Two phones of one model then never share a name. Igor can rename it in any app,
  and the id never changes.
- **Two apps at once.** If two apps make the identity at the same moment, both keep the first one's id.
- **The key is kept before "Paired".** The Cockpit hands a key over once. If the device can't keep it, the app says
  to pair again rather than showing *Paired*.
- **A short drop doesn't end the wait.** Losing the network while waiting keeps the request alive until its
  5 minutes lapse.
- **One re-ask per lapse.** When a service refuses the key, the app shows *Your Cockpit pairing expired, approve
  again?* and starts one new request on its own. Further refusals start no more until a new key arrives, so a lapse
  is one card, not one per failed request. A key past its 90 days counts as lapsed without waiting for a refusal.
- **No pairing screen in BugKit yet.** BugKit gives each app the words and the copyable errors. The app puts them
  beside its own *Pair* button.

## For the keyring side (Larry)

- Up to 3 requests can be open at once, so four apps on a new device asking together would get a *too many* on the
  fourth. Raise the limit per device, or count by `device_id`.
- The card shows `app`, now a short name (`exercise-analyzer`); show `app_label` instead.
- Pairing again replaces the old key by app, origin and device *name*. Key that on `device_id`, so a rename doesn't
  leave an old key live, and two devices given one name don't revoke each other.
- The scopes known today are `ledger:write` and `cockpit:chat`. A new one, such as Exercise Analyzer's workout
  stats, needs adding before an app asks for it, or the start is refused.

## Revocation

- One app: revoke its key in the Cockpit; that app alone shows "pairing expired" and can re-ask.
- A device: "revoke device" in the Cockpit revokes every key that device holds.
- On the device: "Forget this pairing" in an app clears its key only; the shared identity stays for the others.

## Adoption order

1. Think a Card / Stack Trainer (its one-time link is what blocked Igor in context-grabber #1356).
2. Exercise Analyzer (needs a key for live workout stats, exercise-analyzer #376).
3. Context Grabber (move its existing pairing onto the shared flow).

## Open questions for Igor

1. Should a new device's first app pair the others in the background, or should each app pair when first opened?
