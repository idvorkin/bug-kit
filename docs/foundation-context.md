# Foundation context dictionaries

An app with an existing `[String: Any]` context can convert it without a custom adapter:

```swift
let context = try existingContext.mapValues { try JSONValue(foundation: $0) }
```

The throwing initializer accepts `NSNull`, Bool, integer and floating-point `NSNumber` values, String, arrays and dictionaries with String keys, recursively. It distinguishes CFBoolean from numeric `NSNumber(1)` so numeric context stays numeric. It is the inverse of `.foundation` for JSON-compatible values. Unsupported objects, integers outside `Int`'s range and non-finite numbers throw `JSONValue.FoundationConversionError`; catch and log the conversion error at the app's boundary rather than silently dropping fields.

`BugReporterHooks.context` is synchronous and nonthrowing. If the app's context can contain unsupported values, perform and handle this conversion before supplying the hook, or handle the error explicitly inside it. Think a Card can remove its local Foundation-to-JSON switch after pinning BugKit v0.3.2.
