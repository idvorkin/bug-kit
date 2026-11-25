# Pairing

Part of the [BugKit stories](README.md). Igor, 2026-10-18: *"Then I can put pairing code everywhere and have
background authentication"*, then *"drop the key after 1 month; re-auth is easy if it's just a link from Larry on
Telegram"* and *one key per device for every service*. A device pairs once from a link Larry sends; every app of
Igor's on that device then uses the same key for every service on his box, until it expires 30 days later. The
contract with Larry's side (the codes, the redeem, the device registry) is in the design,
`~/tmp/agent/notes/2026-10-18-pairing-and-background-auth.md` §7. BugKit holds the client half: the link, the
redeem, the stored device and the words an app shows. No UI.

---

### User Story 040:

- **Summary:** Pair this device from a link Larry sends
- **From:** think-a-card-trainer's practice ledger (its story 070), the first app to use it
- **Status:** the client half is implemented in 64c0a7e (`PairingLink`, `PairingClient`, `PairedDevice`,
  `KeychainPairedDeviceStore`, `MemoryPairedDeviceStore`).
  - Verified on the host by `PairingTests`:
    - the link's code and https host are read, a link to any host but the app's box or any other link is refused,
      and neither the logged link nor the printed one has the code;
    - the redeem posts the code, the device and what it replaces;
    - expired, used, unknown, too many, unreachable and malformed are each their own error with its words, and an
      answer naming a service off the box is malformed;
    - the device round-trips and never prints its key.
  - Not yet run: the Keychain item in the shared access group (a device check in the first app), and a redeem
    against the box (waits on Larry's `/pair` routes).

#### Use Case:
- **As someone** who uses several of my own apps on one phone
- **I want to** tap one link Larry sends me on Telegram and have every one of those apps signed in
- **so that** I never paste a URL or a key again, and no key ever sits in a chat

#### Acceptance Criteria:
- **Scenario:** Pairing from the link
- **Given:** Larry sent `https://<box>/pair/<code>` and the box's page opened `<scheme>://pair?code=…&host=…` in one
  of my apps
- **When:** the app redeems the code
- **Then:**
  - the device gets its own key with its name, its expiry and the services it opens, kept in one Keychain item on
    this device only, which every app of mine on the device reads;
  - pairing again replaces the device's old key, and the box is told which one it replaces;
  - nothing logged or printed carries the code or the key: the link is logged with its code redacted.

- **Scenario:** A link that no longer works
- **Given:** the link expired (10 minutes), was used already, or is unknown
- **Then:** the app says so in plain words and to ask Larry for another; nothing stored changes.

- **Scenario:** The box is out of reach
- **Given:** the phone is off the tailnet
- **Then:** the app says it could not reach the box and to check Tailscale; the link still works for its 10 minutes.

---

### User Story 041:

- **Summary:** When the key runs out, ask Larry to pair again
- **From:** Igor's answer 2, 2026-10-18 (keys expire after one month)
- **Status:** `PairingStatus` is implemented in 64c0a7e. It is verified on the host by `PairingStatusTests`, which
  check each of the four scenarios' words and that expired, refused and unpaired need pairing. Each app owns what it
  stops sending and what it keeps in the meantime.

#### Use Case:
- **As someone** whose device key lasts a month
- **I want to** be told before it runs out and, once it has, told the one thing to do
- **so that** re-pairing is one tap on Larry's next link, and nothing I did meanwhile is lost

#### Acceptance Criteria:
- **Scenario:** Paired
- **Given:** the device is paired and its key expires in more than 3 days
- **Then:** the app shows *Paired as Igor's iPhone until Nov 17*.

- **Scenario:** About to expire
- **Given:** the key expires within 3 days
- **Then:** the app says how many days are left and that Larry will send a new link.

- **Scenario:** Expired or refused
- **Given:** the key's expiry has passed, or a service answered that it is expired, revoked or unknown
- **Then:** the app says *Ask Larry to pair again* and stops sending with that key; each app keeps what it would
  have sent until the device is paired again.

- **Scenario:** Not paired
- **Then:** the app says the device is not paired and to ask Larry to pair it.

---

## Pairing with the Cockpit by approving a card (bug-kit #144)

Igor, 2026-11-24: *"do we have some kind of shared component so we can share our login key across all of the apps
we have installed?"* He then picked option C: one key per app, plus a device identity every app shares, so that a
new device needs one approval. The design is
[the shared pairing spec](../superpowers/specs/2026-11-24-shared-cockpit-pairing-design.md). The keyring's side,
approving every pending request from one device and revoking a device, is Larry's. The link flow above stays as the
fallback.

---

### User Story 042:

- **Summary:** One identity for this device, shared by every app of mine
- **From:** bug-kit #144, option C
- **Issues:** #144
- **Status:** implemented in COMMIT (`CockpitDevice`, `CockpitDeviceStore`, `KeychainCockpitDeviceStore`,
  `MemoryCockpitDeviceStore`).
  - Verified on the host by `CockpitDeviceTests`. The first app makes the identity and the next one reads it. Two
    apps making it at once agree on one id. A rename keeps the id. The Cockpit's address is shared. The stored names
    match the agreed fields.
  - Not yet run: the Keychain item in the shared access group across two apps on one device (a device check in the
    first two apps to adopt it).

#### Use Case:
- **As someone** with several of my own apps on one phone
- **I want** them to agree on what this device is called and where the Cockpit is
- **so that** the second app pairs with nothing typed, and the Cockpit shows one device, not four

#### Acceptance Criteria:
- **Scenario:** The first app on a new device
- **Given:** no app of mine on this device has paired
- **When:** one of them pairs
- **Then:**
  - it makes a random id that never changes for this device;
  - it names the device after its model and the start of the id, which I can rename;
  - it keeps both on this device only, where every app of mine can read them.

- **Scenario:** The next app
- **Given:** another app already paired
- **When:** this app pairs
- **Then:** it sends the same id and name, and asks the Cockpit the first app used, with nothing typed.

- **Scenario:** Two apps at once
- **Given:** two apps make the identity at the same moment
- **Then:** both end up with the first one's id; neither writes over the other.

---

### User Story 043:

- **Summary:** Pair an app by approving a card in my Inbox
- **From:** bug-kit #144; the request fields agreed with Larry on 2026-11-24
- **Issues:** #144
- **Status:** implemented in COMMIT (`CockpitPairingRequest`, `CockpitPairingClient`, `CockpitPairing.pair`).
  - Verified on the host by `CockpitPairingClientTests` and `CockpitPairingFlowTests`. The start sends exactly
    `app`, `app_label`, `device_id`, `device`, `platform`, `scopes` and `app_version`. The code reaches the app, and
    the poll runs until approved. Deny, lapse, unknown, too many, Inbox down, a bad request, unreachable and malformed
    each get their own words. A service off the Cockpit's host is refused. A short loss of the network keeps the
    wait going, and the wait stops when the request lapses. Neither the handle nor the key is printed.
  - Not yet run: a pairing against the live keyring, which needs an app to adopt it.

#### Use Case:
- **As** Igor
- **I want to** tap *Pair with the Cockpit* and approve one card
- **so that** I never need a code from anyone to sign an app in

#### Acceptance Criteria:
- **Scenario:** Approve
- **Given:** I tapped *Pair with the Cockpit*
- **When:** the app shows *Waiting for you to approve on the Cockpit… code 4F2K* and I approve the card showing
  4F2K
- **Then:** the app shows *Paired* within a few seconds and keeps the Cockpit's address for my other apps.

- **Scenario:** Deny or no answer
- **Given:** I denied the card, or nobody answered within 5 minutes
- **Then:** the app says so in plain words, offers to ask again, and keeps nothing; the error can be copied.

- **Scenario:** Off the tailnet
- **Given:** the phone can't reach the Cockpit
- **Then:** the app says to check Tailscale; a short drop while it waits doesn't end the wait.

---

### User Story 044:

- **Summary:** Each app keeps its own key
- **From:** Igor, 2026-11-22: "One key per app"; kept in option C
- **Issues:** #144
- **Status:** implemented in COMMIT (`CockpitKey`, `CockpitKeyStore`, `KeychainCockpitKeyStore`,
  `MemoryCockpitKeyStore`, `CockpitPairing.forget`).
  - Verified on the host by `CockpitPairingFlowTests`. The approved key is saved before `pair` returns, and a key
    that can't be saved is a loud error. Forget removes this app's key and leaves the shared identity.
  - Not yet run: the key in the app's own Keychain group on a device, unreadable by the other apps.

#### Use Case:
- **As** Igor
- **I want** each app to hold only its own key and scopes
- **so that** I can cut off one app without re-pairing the rest

#### Acceptance Criteria:
- **Scenario:** Approved
- **Then:** the key is kept in this app's own Keychain, on this device only, before the app says *Paired*. If it
  can't be kept, the app says to pair again, because the Cockpit hands a key over only once.

- **Scenario:** Forget this pairing
- **When:** I tap *Forget this pairing* in one app
- **Then:** only that app's key is gone; the other apps and the shared identity are untouched.

---

### User Story 045:

- **Summary:** When an app's key lapses, ask me again, once
- **From:** the spec's step 4: keys lapse after 7 idle days, 90 days at most
- **Issues:** #144
- **Status:** implemented in COMMIT (`CockpitPairingStatus`, `CockpitPairing.status`, `CockpitPairing.keyRefused`).
  - Verified on the host by `CockpitPairingFlowTests`. A refused key, or one past its 90 days, has lapsed and needs
    pairing. The first refusal asks again and later ones don't, until a new key arrives. Each status has its words.
  - BugKit has no pairing screen; each app shows these words with its own button.

#### Use Case:
- **As** Igor
- **I want** an app whose key lapsed to say so and ask again by itself
- **so that** it never fails quietly with a 401, and never fills my Inbox with cards

#### Acceptance Criteria:
- **Scenario:** A service refuses the key
- **Given:** a service answered that the key is expired, revoked or unknown
- **Then:**
  - the app shows *Your Cockpit pairing expired, approve again?* and stops sending the key;
  - it starts one new request on its own;
  - further refusals before a new key start no more.

- **Scenario:** 90 days
- **Given:** the key is 90 days old
- **Then:** the app treats it as lapsed without waiting for a refusal.
