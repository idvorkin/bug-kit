# Apps with extensions

For voice-keyboard and other extensions with a tight memory budget, add the BugKit package product to the **containing application target only**. In Xcode, check the host's General → Frameworks, Libraries, and Embedded Content and Build Phases → Link Binary With Libraries. Remove BugKit from those lists on the keyboard extension. The host embeds its extension normally; that does not require the extension to link the host's libraries.

With XcodeGen, put the package dependency under the host's `dependencies`, and omit it under the extension:

```yaml
packages:
  BugKit:
    url: https://github.com/idvorkin/bug-kit
    exactVersion: 0.3.2
targets:
  Host:
    dependencies:
      - package: BugKit
  Keyboard:
    settings:
      base:
        APPLICATION_EXTENSION_API_ONLY: YES
    # Keep your existing sources and host/embed settings; no BugKit dependency here.
```

Keep the extension's small evidence writer. Give both targets the same App Group entitlement, and have the host attach extension evidence from that container. Use distinct log filenames and let one process own each file; BugKit does not coordinate concurrent cross-process appends. [The integration recipe](integration.md#app-group-storage) describes resolving the shared directory.

For extensions that do have room for the library, `BugReport`, `BugStore`, `BugReportWriter` and `SessionLog` compile with `APPLICATION_EXTENSION_API_ONLY = YES`. The `BugReporter` presenter, report sheet/button and `.bugReporting` modifier are marked unavailable in iOS extensions. CI compiles a real model/store consumer under `-application-extension` and checks that a consumer constructing the host reporter is rejected. There is no extra product or runtime dependency to adopt. Extension-safe compilation does not guarantee an acceptable keyboard memory footprint; host-only linking remains the recommended setup.
