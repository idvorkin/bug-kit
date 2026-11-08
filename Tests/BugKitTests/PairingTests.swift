// Stories 040 and 041: the pairing link, the redeem against a stub of the box, the stored device and the words an
// app shows. Nothing here reaches the network or the Keychain.

import Foundation
#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
import Testing

@testable import BugKit

/// Answers every request with one status and body, and keeps the requests.
private final class StubBox: @unchecked Sendable {
  var status = 200
  var body = Data()
  var failure: URLError?
  var requests: [URLRequest] = []

  var transport: PairingClient.Transport {
    { request in
      self.requests.append(request)
      if let failure = self.failure { throw failure }
      return (
        self.body,
        HTTPURLResponse(
          url: request.url!, statusCode: self.status, httpVersion: nil, headerFields: nil)!
      )
    }
  }
}

private let redeemed = Data(
  """
  {"device_id": "dev_7", "device_key": "dk_s3cret", "name": "Igor's iPhone",
   "expires_at": "2026-11-17T10:00:00.123456-08:00",
   "services": {"ledger": "https://box.example:8451"}}
  """.utf8)

private let link = PairingLink(
  URL(string: "thinkacard://pair?code=ABC234&host=https%3A%2F%2Fbox.example%3A8451")!,
  box: "box.example")!

private let device = PairedDevice(
  deviceID: "dev_7", key: "dk_s3cret", name: "Igor's iPhone",
  expiresAt: Date(timeIntervalSince1970: 1_795_000_000),
  services: ["ledger": URL(string: "https://box.example:8451")!])

@Suite struct PairingLinkTests {
  @Test func readsTheCodeAndTheHost() {
    #expect(link.code == "ABC234")
    #expect(link.host == URL(string: "https://box.example:8451"))
  }

  @Test func anyOtherLinkIsNotAPairing() {
    #expect(PairingLink(URL(string: "thinkacard://think")!, box: "box.example") == nil)
    #expect(
      PairingLink(URL(string: "thinkacard://pair?code=ABC234")!, box: "box.example") == nil,
      "no host")
    #expect(
      PairingLink(
        URL(string: "thinkacard://pair?host=https%3A%2F%2Fbox.example")!, box: "box.example")
        == nil,
      "no code")
    #expect(
      PairingLink(
        URL(string: "thinkacard://pair?code=A&host=http%3A%2F%2Fbox.example")!, box: "box.example")
        == nil,
      "not https")
    #expect(
      PairingLink(
        URL(string: "thinkacard://pair?code=A&host=https%3A%2F%2Fattacker.example")!,
        box: "box.example") == nil,
      "not the box")
    #expect(
      PairingLink(
        URL(string: "thinkacard://pair?code=A&host=https%3A%2F%2Fbox.example.attacker.example")!,
        box: "box.example") == nil,
      "a host that only starts with the box's name")
  }

  @Test func thePrintedLinkHasNoCode() {
    #expect(!"\(link)".contains("ABC234"))
    #expect(!String(reflecting: link).contains("ABC234"))
    var dumped = ""
    dump(link, to: &dumped)
    #expect(!dumped.contains("ABC234"))
    #expect(dumped.contains("box.example"))
  }

  @Test func theLoggedLinkHasNoCode() {
    let logged = PairingLink.redacted(
      URL(string: "thinkacard://pair?code=ABC234&host=https%3A%2F%2Fbox.example")!)
    #expect(!logged.contains("ABC234"))
    #expect(logged.contains("code=redacted"))
    #expect(
      PairingLink.redacted(URL(string: "thinkacard://think?pool=hard")!)
        == "thinkacard://think?pool=hard")
  }
}

@Suite struct PairingClientTests {
  @Test func redeemPostsTheCodeTheDeviceAndWhatItReplaces() async throws {
    let box = StubBox()
    box.body = redeemed
    let paired = try await PairingClient(transport: box.transport).redeem(
      link, device: ["model": "iPhone18,1", "app": "thinkacard"], replacing: "dev_6")

    let request = try #require(box.requests.first)
    #expect(request.httpMethod == "POST")
    #expect(request.url == URL(string: "https://box.example:8451/pair/redeem"))
    let sent = try #require(
      JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
    #expect(sent["code"] as? String == "ABC234")
    #expect(sent["replaces"] as? String == "dev_6")
    #expect((sent["device"] as? [String: String])?["app"] == "thinkacard")

    #expect(paired.deviceID == "dev_7")
    #expect(paired.key == "dk_s3cret")
    #expect(paired.name == "Igor's iPhone")
    #expect(paired.services["ledger"] == URL(string: "https://box.example:8451"))
    #expect(
      abs(paired.expiresAt.timeIntervalSince1970 - 1_794_938_400.123) < 0.01,
      "an offset and fractions")
  }

  @Test func aFirstPairingSendsNoReplaces() async throws {
    let box = StubBox()
    box.body = redeemed
    _ = try await PairingClient(transport: box.transport).redeem(link, device: [:], replacing: nil)
    let sent = try #require(
      JSONSerialization.jsonObject(with: box.requests[0].httpBody ?? Data()) as? [String: Any])
    #expect(sent["replaces"] == nil)
  }

  @Test(arguments: [
    (410, PairingError.expired), (409, .used), (404, .unknown), (429, .tooMany),
    (500, .refused(500)),
  ])
  func aLinkThatNoLongerWorksSaysWhy(status: Int, error: PairingError) async {
    let box = StubBox()
    box.status = status
    box.body = Data(#"{"error": "whatever"}"#.utf8)
    await #expect(throws: error) {
      try await PairingClient(transport: box.transport).redeem(link, device: [:], replacing: nil)
    }
  }

  @Test func offTheTailnetIsUnreachable() async {
    let box = StubBox()
    box.failure = URLError(.cannotFindHost)
    await #expect(throws: PairingError.unreachable) {
      try await PairingClient(transport: box.transport).redeem(link, device: [:], replacing: nil)
    }
  }

  @Test func anAnswerWithoutAKeyIsMalformed() async {
    let box = StubBox()
    box.body = Data(#"{"device_id": "dev_7"}"#.utf8)
    await #expect(throws: PairingError.malformed) {
      try await PairingClient(transport: box.transport).redeem(link, device: [:], replacing: nil)
    }
  }

  @Test(arguments: ["https://attacker.example:8451", "http://box.example:8451"])
  func aServiceOffTheBoxIsMalformed(service: String) async {
    let box = StubBox()
    box.body = Data(
      """
      {"device_id": "dev_7", "device_key": "dk_s3cret", "name": "Igor's iPhone",
       "expires_at": "2026-11-17T10:00:00-08:00", "services": {"ledger": "\(service)"}}
      """.utf8)
    await #expect(throws: PairingError.malformed) {
      try await PairingClient(transport: box.transport).redeem(link, device: [:], replacing: nil)
    }
  }

  @Test func theWordsSayWhatToDo() {
    #expect(PairingError.expired.message == "That link has expired. Ask Larry to pair again.")
    #expect(PairingError.used.message == "That link was already used. Ask Larry to pair again.")
    #expect(PairingError.unreachable.message.contains("Tailscale"))
  }
}

@Suite struct PairedDeviceTests {
  @Test func itRoundTripsAndNeverPrintsTheKey() throws {
    let back = try JSONDecoder().decode(PairedDevice.self, from: JSONEncoder().encode(device))
    #expect(back == device)
    #expect(!"\(device)".contains("dk_s3cret"))
    #expect(!String(reflecting: device).contains("dk_s3cret"))
  }

  @Test func theStoreKeepsOneDevice() throws {
    let store = MemoryPairedDeviceStore()
    #expect(store.load() == nil)
    try store.save(device)
    #expect(store.load() == device)
    store.remove()
    #expect(store.load() == nil)
  }
}

@Suite struct PairingStatusTests {
  private let now = Date(timeIntervalSince1970: 1_795_000_000)
  private let en = Locale(identifier: "en_US")
  private let pacific = TimeZone(identifier: "America/Los_Angeles")!

  private func paired(inDays days: Double) -> PairedDevice {
    PairedDevice(
      deviceID: "d", key: "k", name: "Igor's iPhone",
      expiresAt: now.addingTimeInterval(days * 86_400), services: [:])
  }

  @Test func pairedSaysUntilWhen() {
    let status = PairingStatus(device: paired(inDays: 20), refused: false, now: now)
    #expect(status == .paired(name: "Igor's iPhone", until: now.addingTimeInterval(20 * 86_400)))
    #expect(!status.needsPairing)
    #expect(status.message(locale: en, timeZone: pacific) == "Paired as Igor's iPhone until Dec 8")
  }

  @Test func withinThreeDaysItSaysHowManyAndThatLarryWillSendALink() {
    let status = PairingStatus(device: paired(inDays: 2.5), refused: false, now: now)
    #expect(status == .expiring(name: "Igor's iPhone", days: 3))
    #expect(!status.needsPairing)
    #expect(
      status.message(locale: en, timeZone: pacific)
        == "Igor's iPhone's key expires in 3 days. Larry will send a new link.")
    #expect(
      PairingStatus(device: paired(inDays: 0.5), refused: false, now: now).message(
        locale: en, timeZone: pacific)
        == "Igor's iPhone's key expires in 1 day. Larry will send a new link.")
  }

  @Test func expiredOrRefusedAsksForANewPairing() {
    let expired = PairingStatus(device: paired(inDays: -1), refused: false, now: now)
    #expect(expired == .expired(name: "Igor's iPhone"))
    #expect(expired.needsPairing)
    #expect(
      expired.message(locale: en, timeZone: pacific)
        == "Igor's iPhone's key has expired. Ask Larry to pair again.")

    #expect(
      PairingStatus(device: paired(inDays: -1), refused: true, now: now) == .expired(name: "Igor's iPhone"),
      "an expired key the box also refused says expired")

    let refused = PairingStatus(device: paired(inDays: 20), refused: true, now: now)
    #expect(refused == .refused(name: "Igor's iPhone"))
    #expect(refused.needsPairing)
    #expect(
      refused.message(locale: en, timeZone: pacific)
        == "The box refused Igor's iPhone's key. Ask Larry to pair again.")
  }

  @Test func notPairedAsksLarry() {
    let status = PairingStatus(device: nil, refused: false, now: now)
    #expect(status == .unpaired)
    #expect(status.needsPairing)
    #expect(
      status.message(locale: en, timeZone: pacific) == "Not paired. Ask Larry to pair this device.")
  }
}
