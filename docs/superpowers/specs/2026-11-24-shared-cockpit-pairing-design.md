# Shared Cockpit pairing across Igor's apps (design proposal, #144)

Status: proposal for Igor's choice. No code until he picks an option.

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

## Recommendation

**C.** Keep one key per app, so each app holds only its own scopes and can be revoked alone, which was Igor's 11/22
reason. Share what's harmless to share: the device's identity (its label and the Cockpit's address) in a keychain
group all of Igor's apps can read, so the second app on a device needs nothing typed. Ask keyring for one small
addition, "approve every pending request from this device" on the card, so a new phone is one tap even with four
apps. If Igor prefers fewest moving parts over per-app revocation, B is simpler and works today.

## What's shared, and where

- **BugKit owns** the pairing flow (start, wait, poll, store, re-pair on expiry), its screen and its copyable errors,
  and the shared device identity. Every app already embeds BugKit, so no new dependency.
- **Each app owns** its own key, the scopes it asks for, and where its "Pair" button sits.
- **Storage:** each key in the app's own keychain; the device identity in a keychain group shared by Igor's apps,
  which requires them all to be signed by the same team (they are).

## Revocation

- One app: revoke its key in the Cockpit; that app alone shows "pairing expired" and can re-ask.
- A device: "revoke device" in the Cockpit revokes every key that device holds.
- On the device: "Forget this pairing" in an app clears its key only; the shared identity stays for the others.

## Adoption order

1. Think a Card / Stack Trainer (its one-time link is what blocked Igor in context-grabber #1356).
2. Exercise Analyzer (needs a key for live workout stats, exercise-analyzer #376).
3. Context Grabber (move its existing pairing onto the shared flow).

## Open questions for Igor

1. A (one key per app, a card each), B (one shared key), or C (per-app keys, one-tap device approval)?
   Recommended: C.
2. Should a new device's first app pair the others in the background, or should each app pair when first opened?
