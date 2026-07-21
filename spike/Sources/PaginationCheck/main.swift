import Foundation
import SynoKit
import FotoKit

// CHK-1: does the collapsed-timeline pagination (LibraryViewModel pages
// `similarPage(offset: items.count, ...)`) drop or duplicate rows? Read-only.
// Uses the Photos app's own credential store — the password never leaves this
// process.

SecureLocalStore.appDirectoryName = "SynologyPhotosManager"
SecureLocalStore.serviceNamespace = "com.synokit"

guard let connection = CredentialStore.savedConnections().first,
      let password = CredentialStore.password(for: connection) else {
    print("no stored connection/password found for the Photos app"); exit(2)
}
print("NAS: \(connection.id)  user: \(connection.username)\n")

let svc = FotoService(connection: connection, space: .personal)
do {
    try await svc.connect(username: connection.username, password: password)
} catch {
    print("connect failed: \(error)"); exit(3)
}

let rawCount = (try? await svc.itemCount()) ?? -1
print("raw itemCount (Browse.Item count): \(rawCount)")

// 1) Page exactly like the app: offset = number collected so far, limit 400.
let pageSize = 400
var paged: [Int] = []
var pages = 0
do {
    while true {
        let page = try await svc.similarPage(offset: paged.count, limit: pageSize)
        if page.isEmpty { break }
        paged.append(contentsOf: page.map(\.id))
        pages += 1
        if pages > 1000 { print("aborting: too many pages (loop?)"); break }
    }
} catch {
    print("paged fetch failed: \(error)"); exit(4)
}
let pagedUnique = Set(paged)
let dupCount = paged.count - pagedUnique.count
print("paged: \(pages) pages, \(paged.count) rows, \(pagedUnique.count) unique, \(dupCount) duplicate ids")

// 2) Ground truth: one big-limit request (no pagination).
var single: [FotoItem] = []
do {
    single = try await svc.similarPage(offset: 0, limit: max(rawCount, paged.count) + 500)
} catch {
    print("single-shot fetch failed: \(error)"); exit(5)
}
let singleSet = Set(single.map(\.id))
print("single-shot: \(single.count) rows, \(singleSet.count) unique\n")

// 3) Compare the two.
let skipped = singleSet.subtracting(pagedUnique)   // in ground truth, missed by paging
let extra = pagedUnique.subtracting(singleSet)      // paged in, absent from ground truth
print("rows single-shot has but paging skipped: \(skipped.count)")
print("rows paging returned but single-shot lacks: \(extra.count)")

if dupCount == 0 && skipped.isEmpty && extra.isEmpty {
    print("\n✅ CHK-1: collapsed-timeline pagination is CORRECT (no duplicates, no skips)")
} else {
    print("\n❌ CHK-1: pagination MISMATCH — offset=items.count drifts vs the server's paging unit")
}

await svc.disconnect()
