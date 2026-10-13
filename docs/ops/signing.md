# Keeping automatic signing working

## The model

- **The projects use automatic signing.** XcodeGen `project.yml` sets `DEVELOPMENT_TEAM: <team-id>` and `CODE_SIGN_STYLE: Automatic`.
- **There is no API key, no fastlane and no hand-made profile.** The only credential is the Apple ID session that the Xcode app holds.
- **Profiles are cached** in `~/Library/Developer/Xcode/UserData/Provisioning Profiles/`. The older `~/Library/MobileDevice/Provisioning Profiles/` is empty on current Xcode.

## Which builds need the account

**No account needed:**
- **Covered builds.** When the cached profiles already cover the device and every entitlement, `-allowProvisioningUpdates` changes nothing and the build signs offline.
- **New plain bundle ids.** The wildcard "iOS Team Provisioning Profile: *" covers a brand-new bundle id with no special capabilities.

**Account needed:** anything that changes the developer portal:
- a device that is not in the profile yet (the first build for a new iPad);
- a new capability or entitlement: iCloud, App Groups, HealthKit.

Without the account these fail with:

```
error: No Accounts: Add a new account in Accounts settings.
error: Provisioning profile "iOS Team Provisioning Profile: <bundle-id>" doesn't include the <X> capability.
error: Provisioning profile "…" doesn't support the iCloud.<bundle-id> iCloud Identifier.
error: Provisioning profile "…" doesn't support the group.<bundle-id> App Group
```

The apps hit each of these:
- EA, the iCloud container for sync (EA #209/#211), and HealthKit for the watch;
- CG, a new App Group;
- both, a new iPad.

## Checking whether the account is there

- **The only reliable check is one device build that needs the portal.** Grep its output for `No Accounts`.
- **Don't trust `defaults read com.apple.dt.Xcode DVTDeveloperAccountManagerAppleIDLists`.** In Xcode 27 it listed the account while builds failed with No Accounts, and it was empty while a build signed and registered a new device.
- **Do not dump keychain credentials.** Xcode 27 uses the data-protection keychain service
  `com.apple.dt.Xcode.KeychainService`; locked-screen reads can be denied with `-25308`.
- **When reading Xcode's unified log,** use `/usr/bin/log`, because in zsh `log` is a builtin. Read it within the hour. Filter out token, session, password and authorization lines before writing anything down: one search once captured a live session token. The header names to drop are `X-Apple-GS-Token` and `DSESSIONID` (CG), as in `/usr/bin/log show … | grep -v -i -E 'X-Apple-GS-Token|DSESSIONID|token|password|authorization'`.

## Fixing it

1. Have the person sign in at **Xcode › Settings › Accounts**. There is no command-line sign-in.
2. Unlock the Mac, then run the build that needs the portal, **first and alone**, under the lock and
   `scripts/signing-guard.sh`. It registers the device or adds the capability, and Xcode caches the new profile.
3. From then on, builds that need no new portal change keep working even if the account drops again. The iCloud capability is the usual case: one signing build after sign-in, then cached-profile builds work.

The driver analysis in [BugKit #53](https://github.com/idvorkin/bug-kit/issues/53) attributes the repeated
2026-10-11/12 account losses to provisioning builds while the Mac was locked. On 10-12 the screen locked
at 18:28:16; a lone unsandboxed signing build at 18:36:40 encountered a denied data-protection keychain
read (`-25308`) and Xcode discarded the account. Unlocking afterward did not restore it. Concurrency,
sandboxing, defaults writes and token expiry were ruled out for that incident. Keep the signing lock for
serialization; it does not make a locked-screen build safe.

## No provisioning builds while the Mac is locked

Every app's signing recipe must run the shared guard **inside** `xcode-signing.lock`. Cached profiles do
not exempt a command that passes `-allowProvisioningUpdates`: it can still read the account keychain. The guard checks
`ioreg -n Root -d1` for `"CGSSessionScreenIsLocked" = Yes` and waits for the person to unlock the Mac before
starting the build. It runs `caffeinate -d -w $$` for its lifetime, including the build, then cleans up the
assertion. `caffeinate -i` alone does not prevent display sleep and the immediate screen lock. The guard
refuses to start if the lock-state query fails or the display assertion process exits.

One-line adoption in each app's existing device recipe (substitute its BugKit checkout and build args):

```sh
lockf -k -t 900 ~/tmp/agent/locks/xcode-signing.lock "$BUG_KIT/scripts/signing-guard.sh" xcodebuild <existing-build-args>
```

Create the lock directory first. Keep the outer build turn and `build.lock` rules; do not reacquire either
lock if the caller already holds it. `scripts/deploy-all.sh` and the signed
`python3 scripts/build-cloudkit-reader.py` path already invoke the guard inside their signing lock;
calling recipes must not add a second signing lock around them. The unsigned reader path needs no guard.

If build output contains **No Accounts** or **Failed to load credentials**, the guard returns 78 even if
the command reports success. Stop, tell the person, and never retry or install automatically. The person
must unlock and check **Xcode › Settings › Accounts**; sign in again only if needed, then explicitly
request a new guarded attempt. Other build failures keep their original nonzero exit status.

The display assertion prevents automatic display sleep; it cannot override a person manually locking
the screen during a build. Leave the Mac unlocked until signing finishes. Host checks use fake ioreg,
caffeinate and build tools. The real `=Yes` wait/unlock behavior and display assertion remain to verify
in the next granted build turn, without starting a provisioning build while locked.

## Don'ts

- **Don't strip entitlements from `project.yml` to get a build through.** The app then ships without the capability: a widget showed only its placeholder. A new device still fails, because it is in no cached profile (CG, 2026-10-06/07).
- **Don't clear the cached profiles while the account is unreliable.** Builds that work would start failing.
- **Don't run two signing builds at once** (see [deploying.md](deploying.md)).

## A new device

1. Find it in `xcrun devicectl list devices`. Keep its id out of the repo: use a gitignored file or none at all, because the scripts here find devices by model.
2. With the account signed in and no other signing build running, build once with that device as the destination and `-allowProvisioningDeviceRegistration`: `scripts/deploy-all.sh <app> --register <device>`.
3. From then on, normal builds and installs cover it.

## Simulator builds

Simulator builds need no team:
- EA uses `CODE_SIGNING_ALLOWED=NO`.
- CG uses `CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual`, "signed to run locally, not unsigned": HealthKit refuses an app without its entitlement, even on the simulator.
- A Mac app built ad hoc (`codesign --force --sign -`) loses its Accessibility grant at every rebuild.

## Mac apps signed ad hoc

- **Every rebuild changes an ad-hoc signature, and macOS may ask for camera, microphone or screen-recording access again.** TCC ties the grant to the signature. When relaunching a rebuilt Mac app, tell the person a permission prompt may be waiting. Otherwise the app looks frozen on a blank camera (MM AGENTS.md).
