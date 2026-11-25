// Stories 042 to 045: pairing with the Cockpit by approving a card (bug-kit #144, option C). The shared device
// identity, the request every app sends, the poll until Igor answers, the per-app key, and what an app shows.
// Nothing here reaches the network or the Keychain: the stores are the memory ones and the Cockpit is a stub.

import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
import Testing

@testable import BugKit

/// Answers each request with the next scripted reply (the last one repeats), and keeps the requests.
private final class StubCockpit: @unchecked Sendable {
  var replies: [(Int, String)] = []
  var failure: URLError?
  var requests: [URLRequest] = []

  var transport: CockpitPairingClient.Transport {
    { request in
      self.requests.append(request)
      if let failure = self.failure { throw failure }
      let (status, body) = self.replies.count > 1 ? self.replies.removeFirst() : self.replies[0]
      return (
        Data(body.utf8),
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
      )
    }
  }

  func sent(_ index: Int) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: requests[index].httpBody ?? Data()) as? [String: Any])
  }
}

private let cockpit = URL(string: "https://box.example:8456")!

private let started = """
  {"code": "MZQP", "handle": "ph_s3cret-handle", "expires_at": "2026-11-24T18:05:00.000000+00:00",
   "poll_every_s": 2}
  """
private let pending = #"{"state": "pending", "code": "MZQP", "expires_at": "2026-11-24T18:05:00.000000+00:00"}"#
private let approved = """
  {"state": "approved", "key_id": "app_0123", "key": "ak_s3cret-key", "app": "exercise-analyzer",
   "name": "iPhone18,1 7F3A", "scopes": ["ledger:write"], "expires_at": "2026-12-01T18:00:00.000000+00:00",
   "hard_expires_at": "2027-02-22T18:00:00.000000+00:00", "services": {"ledger": "https://box.example:8451"}}
  """

private let request = CockpitPairingRequest(
  app: "exercise-analyzer", appLabel: "Exercise Analyzer", scopes: ["ledger:write"], appVersion: "2.0.0 (3675)",
  platform: .iOS)

/// When the request starts; it lapses five minutes later, at 18:05.
private let morning = Date(timeIntervalSince1970: 1_795_543_200)  // 2026-11-24T18:00:00Z

@MainActor
private func pairing(
  _ stub: StubCockpit, devices: MemoryCockpitDeviceStore = MemoryCockpitDeviceStore(),
  keys: MemoryCockpitKeyStore = MemoryCockpitKeyStore(), clock: Clock = Clock()
) -> CockpitPairing {
  CockpitPairing(
    request: request, devices: devices, keys: keys, client: CockpitPairingClient(transport: stub.transport),
    defaultLabel: { "iPhone18,1" }, now: { clock.now }, sleep: { clock.now += $0 })
}

/// A clock the flow's sleeps move forward, so a test never waits.
private final class Clock: @unchecked Sendable {
  var now = morning
}

@Suite struct CockpitDeviceTests {
  @Test func theFirstAppMakesTheIdentityAndTheRestReadIt() throws {
    let shared = MemoryCockpitDeviceStore()
    let first = try shared.identity(defaultLabel: { "iPhone18,1" })
    let second = try shared.identity(defaultLabel: { "something else" })
    #expect(first == second, "the second app reads the first one's identity")
    #expect(UUID(uuidString: first.deviceID) != nil)
    #expect(first.label.hasPrefix("iPhone18,1 "), "the default label is the model and a short id")
    #expect(first.label.hasSuffix(String(first.deviceID.prefix(4)).uppercased()))
  }

  @Test func twoAppsMakingItAtOnceAgreeOnOneID() throws {
    // The other app's add lands between this one's read and its add: the add refuses, and this app reads the
    // winner instead of writing over it.
    let shared = MemoryCockpitDeviceStore()
    let winner = CockpitDevice(deviceID: UUID().uuidString, label: "Igor's iPhone", cockpit: nil)
    shared.beforeNextInsert = { shared.stored = winner }
    #expect(try shared.identity(defaultLabel: { "iPhone18,1" }) == winner)
    #expect(shared.stored == winner)
  }

  @Test func renamingKeepsTheID() throws {
    let shared = MemoryCockpitDeviceStore()
    let made = try shared.identity(defaultLabel: { "iPhone18,1" })
    let renamed = try shared.rename(to: "  Igor's iPhone 17 Pro ")
    #expect(renamed.deviceID == made.deviceID)
    #expect(renamed.label == "Igor's iPhone 17 Pro")
    #expect(shared.stored == renamed)
  }

  @Test func theCockpitsAddressIsSharedToo() throws {
    let shared = MemoryCockpitDeviceStore()
    _ = try shared.identity(defaultLabel: { "iPhone18,1" })
    try shared.remember(cockpit: cockpit)
    #expect(shared.load()?.cockpit == cockpit)
  }

  @Test func aPlainHTTPAddressIsNeverShared() throws {
    let shared = MemoryCockpitDeviceStore()
    _ = try shared.identity(defaultLabel: { "iPhone18,1" })
    try shared.remember(cockpit: URL(string: "http://box.example:8456")!)
    #expect(shared.load()?.cockpit == nil)
  }

  @Test func itRoundTripsWithTheAgreedNames() throws {
    let device = CockpitDevice(deviceID: "D1", label: "Igor's iPad", cockpit: cockpit)
    let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(device)) as? [String: Any])
    #expect(json["device_id"] as? String == "D1")
    #expect(json["label"] as? String == "Igor's iPad")
    #expect(try JSONDecoder().decode(CockpitDevice.self, from: JSONEncoder().encode(device)) == device)
  }
}

@Suite struct CockpitPairingClientTests {
  @Test func startSendsEveryAgreedField() async throws {
    let stub = StubCockpit()
    stub.replies = [(201, started)]
    let device = CockpitDevice(deviceID: "D1", label: "Igor's iPhone 17 Pro", cockpit: nil)
    let start = try await CockpitPairingClient(transport: stub.transport).start(request, device: device, at: cockpit)

    let sent = stub.requests[0]
    #expect(sent.httpMethod == "POST")
    #expect(sent.url == URL(string: "https://box.example:8456/pair/start"))
    #expect(sent.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try stub.sent(0)
    #expect(body["app"] as? String == "exercise-analyzer")
    #expect(body["app_label"] as? String == "Exercise Analyzer")
    #expect(body["device_id"] as? String == "D1")
    #expect(body["device"] as? String == "Igor's iPhone 17 Pro")
    #expect(body["platform"] as? String == "iOS")
    #expect(body["scopes"] as? [String] == ["ledger:write"])
    #expect(body["app_version"] as? String == "2.0.0 (3675)")
    #expect(Set(body.keys) == ["app", "app_label", "device_id", "device", "platform", "scopes", "app_version"])

    #expect(start.code == "MZQP")
    #expect(start.handle == "ph_s3cret-handle")
    #expect(start.pollEvery == 2)
    #expect(start.expiresAt == Date(timeIntervalSince1970: 1_795_543_500))
  }

  @Test func theStartWithoutAPollIntervalPollsEveryTwoSeconds() async throws {
    let stub = StubCockpit()
    stub.replies = [(201, #"{"code": "MZQP", "handle": "ph_x", "expires_at": "2026-11-24T18:05:00+00:00"}"#)]
    let start = try await CockpitPairingClient(transport: stub.transport).start(
      request, device: CockpitDevice(deviceID: "D1", label: "L", cockpit: nil), at: cockpit)
    #expect(start.pollEvery == 2)
  }

  @Test func pollSendsTheHandleAndReadsTheKey() async throws {
    let stub = StubCockpit()
    stub.replies = [(202, pending), (200, approved)]
    let client = CockpitPairingClient(transport: stub.transport)
    #expect(try await client.poll("ph_s3cret-handle", at: cockpit) == .pending)
    guard case .approved(let key) = try await client.poll("ph_s3cret-handle", at: cockpit) else {
      Issue.record("not approved")
      return
    }
    #expect(stub.requests[0].url == URL(string: "https://box.example:8456/pair/poll"))
    #expect(try stub.sent(0)["handle"] as? String == "ph_s3cret-handle")
    #expect(key.keyID == "app_0123")
    #expect(key.key == "ak_s3cret-key")
    #expect(key.scopes == ["ledger:write"])
    #expect(key.services["ledger"] == URL(string: "https://box.example:8451"))
    #expect(key.hardExpiresAt == Date(timeIntervalSince1970: 1_803_319_200))
  }

  @Test(arguments: [
    (403, #"{"error": "denied"}"#, CockpitPairingError.denied),
    (410, #"{"error": "expired"}"#, .expired),
    (404, #"{"error": "unknown"}"#, .unknown),
    (429, #"{"error": "too_many"}"#, .tooMany),
    (503, #"{"error": "inbox_down", "detail": "bd failed"}"#, .inboxDown),
    (
      400, #"{"error": "bad_scope", "detail": "unknown scopes ['workout']"}"#,
      .badRequest("unknown scopes ['workout']")
    ),
    (500, "oops", .refused(500)),
  ])
  func eachRefusalIsItsOwnError(status: Int, body: String, error: CockpitPairingError) async {
    let stub = StubCockpit()
    stub.replies = [(status, body)]
    await #expect(throws: error) {
      _ = try await CockpitPairingClient(transport: stub.transport).poll("ph_x", at: cockpit)
    }
    #expect(!error.message.isEmpty)
  }

  @Test func offTheTailnetIsUnreachable() async {
    let stub = StubCockpit()
    stub.failure = URLError(.notConnectedToInternet)
    await #expect(throws: CockpitPairingError.unreachable) {
      _ = try await CockpitPairingClient(transport: stub.transport).start(
        request, device: CockpitDevice(deviceID: "D1", label: "L", cockpit: nil), at: cockpit)
    }
  }

  @Test func aKeyForAServiceOffTheCockpitsHostIsMalformed() async {
    let stub = StubCockpit()
    stub.replies = [(200, approved.replacingOccurrences(of: "https://box.example:8451", with: "https://evil.example"))]
    await #expect(throws: CockpitPairingError.malformed) {
      _ = try await CockpitPairingClient(transport: stub.transport).poll("ph_x", at: cockpit)
    }
  }

  @Test func nothingPrintedCarriesTheHandleOrTheKey() async throws {
    let stub = StubCockpit()
    stub.replies = [(201, started), (200, approved)]
    let client = CockpitPairingClient(transport: stub.transport)
    let start = try await client.start(
      request, device: CockpitDevice(deviceID: "D1", label: "L", cockpit: nil), at: cockpit)
    guard case .approved(let key) = try await client.poll(start.handle, at: cockpit) else { return }
    for printed in [
      "\(start)", String(reflecting: start), "\(key)", String(reflecting: key), dumped(start), dumped(key),
    ] {
      #expect(!printed.contains("s3cret"), "\(printed)")
    }
  }
}

private func dumped(_ value: some Any) -> String {
  var out = ""
  dump(value, to: &out)
  return out
}

@Suite @MainActor struct CockpitPairingFlowTests {
  @Test func approvedStoresTheKeyAndTheCockpit() async throws {
    let stub = StubCockpit()
    stub.replies = [(201, started), (202, pending), (202, pending), (200, approved)]
    let devices = MemoryCockpitDeviceStore()
    let keys = MemoryCockpitKeyStore()
    var codes: [String] = []
    let flow = pairing(stub, devices: devices, keys: keys)

    let key = try await flow.pair(cockpit: cockpit) { codes.append($0) }

    #expect(codes == ["MZQP"])
    #expect(keys.load(app: "exercise-analyzer") == key)
    #expect(devices.load()?.cockpit == cockpit, "the next app needs nothing typed")
    #expect(stub.requests.count == 4)
    #expect(flow.status(now: morning) == .paired(until: key.hardExpiresAt))
  }

  @Test func theSecondAppUsesTheSharedIdentityAndAddress() async throws {
    let stub = StubCockpit()
    stub.replies = [(201, started), (200, approved)]
    let devices = MemoryCockpitDeviceStore(
      CockpitDevice(deviceID: "D1", label: "Igor's iPhone", cockpit: cockpit))
    _ = try await pairing(stub, devices: devices).pair(cockpit: nil) { _ in }
    #expect(stub.requests[0].url == URL(string: "https://box.example:8456/pair/start"))
    #expect(try stub.sent(0)["device_id"] as? String == "D1")
    #expect(try stub.sent(0)["device"] as? String == "Igor's iPhone")
  }

  @Test func noAddressAnywhereSaysSo() async {
    let stub = StubCockpit()
    await #expect(throws: CockpitPairingError.noCockpit) {
      _ = try await pairing(stub).pair(cockpit: nil) { _ in }
    }
    #expect(stub.requests.isEmpty)
  }

  @Test func aPlainHTTPAddressIsRefusedBeforeAnythingIsSent() async {
    let http = URL(string: "http://box.example:8456")!
    let typed = StubCockpit()
    let devices = MemoryCockpitDeviceStore()
    await #expect(throws: CockpitPairingError.notHTTPS) {
      _ = try await pairing(typed, devices: devices).pair(cockpit: http) { _ in }
    }
    #expect(typed.requests.isEmpty)
    #expect(devices.load()?.cockpit == nil)

    let shared = StubCockpit()
    let sharedHTTP = MemoryCockpitDeviceStore(CockpitDevice(deviceID: "D1", label: "Igor's iPhone", cockpit: http))
    await #expect(throws: CockpitPairingError.notHTTPS) {
      _ = try await pairing(shared, devices: sharedHTTP).pair(cockpit: nil) { _ in }
    }
    #expect(shared.requests.isEmpty)
  }

  @Test func pollingAPlainHTTPAddressSendsNothing() async {
    let stub = StubCockpit()
    await #expect(throws: CockpitPairingError.notHTTPS) {
      _ = try await CockpitPairingClient(transport: stub.transport).poll("h1", at: URL(string: "http://box.example:8456")!)
    }
    #expect(stub.requests.isEmpty)
  }

  @Test func deniedStoresNothing() async {
    let stub = StubCockpit()
    stub.replies = [(201, started), (403, #"{"error": "denied"}"#)]
    let keys = MemoryCockpitKeyStore()
    await #expect(throws: CockpitPairingError.denied) {
      _ = try await pairing(stub, keys: keys).pair(cockpit: cockpit) { _ in }
    }
    #expect(keys.load(app: "exercise-analyzer") == nil)
  }

  @Test func itStopsPollingWhenTheRequestLapses() async {
    let stub = StubCockpit()
    stub.replies = [(201, started), (202, pending)]
    await #expect(throws: CockpitPairingError.expired) {
      _ = try await pairing(stub).pair(cockpit: cockpit) { _ in }
    }
    // 5 minutes at one poll every 2 seconds: about 150 polls, never more.
    #expect(stub.requests.count <= 152)
  }

  @Test func aBlipOffTheTailnetKeepsWaiting() async throws {
    let stub = StubCockpit()
    stub.replies = [(201, started), (202, pending), (200, approved)]
    let blip = StubCockpit()
    blip.replies = [(0, "")]
    let client = CockpitPairingClient(transport: { request in
      blip.requests.append(request)
      if blip.requests.count == 2 { throw URLError(.networkConnectionLost) }
      return try await stub.transport(request)
    })
    let flow = CockpitPairing(
      request: request, devices: MemoryCockpitDeviceStore(), keys: MemoryCockpitKeyStore(), client: client,
      defaultLabel: { "iPhone18,1" }, now: { morning }, sleep: { _ in })
    let key = try await flow.pair(cockpit: cockpit) { _ in }
    #expect(key.keyID == "app_0123")
    #expect(blip.requests.count == 4, "start, the lost poll, pending, approved")
  }

  @Test func aKeyThatCannotBeSavedIsALoudError() async {
    let stub = StubCockpit()
    stub.replies = [(201, started), (200, approved)]
    let keys = MemoryCockpitKeyStore()
    keys.refuse = true
    await #expect(throws: CockpitPairingError.notSaved("refused 0")) {
      _ = try await pairing(stub, keys: keys).pair(cockpit: cockpit) { _ in }
    }
  }

  @Test func forgetClearsOnlyThisAppsKey() async throws {
    let stub = StubCockpit()
    stub.replies = [(201, started), (200, approved)]
    let devices = MemoryCockpitDeviceStore()
    let keys = MemoryCockpitKeyStore()
    let flow = pairing(stub, devices: devices, keys: keys)
    _ = try await flow.pair(cockpit: cockpit) { _ in }
    flow.forget()
    #expect(keys.load(app: "exercise-analyzer") == nil)
    #expect(devices.load() != nil, "the shared identity stays for the other apps")
    #expect(flow.status() == .unpaired)
  }

  @Test func aRefusedKeyAsksAgainOncePerLapse() async throws {
    let stub = StubCockpit()
    stub.replies = [(201, started), (200, approved)]
    let flow = pairing(stub)
    _ = try await flow.pair(cockpit: cockpit) { _ in }

    #expect(flow.keyRefused(), "the first refusal asks again on its own")
    #expect(flow.status(now: morning) == .lapsed)
    #expect(flow.status().needsPairing)
    #expect(!flow.keyRefused(), "a second refusal before a new key does not start another card")

    stub.replies = [(201, started), (200, approved)]
    _ = try await flow.pair(cockpit: cockpit) { _ in }
    #expect(flow.status(now: morning) == .paired(until: Date(timeIntervalSince1970: 1_803_319_200)))
    #expect(flow.keyRefused(), "a new key's lapse asks again")
  }

  @Test func pastTheHardExpiryItHasLapsed() async throws {
    let stub = StubCockpit()
    stub.replies = [(201, started), (200, approved)]
    let flow = pairing(stub)
    _ = try await flow.pair(cockpit: cockpit) { _ in }
    #expect(flow.status(now: Date(timeIntervalSince1970: 1_803_319_201)) == .lapsed)
  }

  @Test func theWordsAppsShow() {
    #expect(
      CockpitPairingStatus.waiting(code: "4F2K").message == "Waiting for you to approve on the Cockpit… code 4F2K")
    #expect(CockpitPairingStatus.lapsed.message == "Your Cockpit pairing expired, approve again?")
    #expect(CockpitPairingStatus.unpaired.needsPairing)
    #expect(!CockpitPairingStatus.paired(until: morning).needsPairing)
  }

  @Test func anErrorIsCopyable() {
    let problem = CockpitPairingError.denied.problem(context: "settings: pair with the Cockpit")
    #expect(problem.context == "settings: pair with the Cockpit")
    #expect(problem.message == CockpitPairingError.denied.message)
    #expect(problem.extra["error"] == .string("denied"))
  }
}
