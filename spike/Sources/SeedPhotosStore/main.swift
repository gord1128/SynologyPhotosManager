import Foundation
import CryptoKit
import SynoKit

// Read the connection + password + cert pin from SynologyMonitor's store, then
// write them into the Photos app's own store (its config: appDirectoryName
// "SynologyPhotosManager", default serviceNamespace "com.synokit", no legacy
// key). Lets the unsandboxed app auto-connect for a screenshot smoke test.

// 1) Source: SynologyMonitor store.
SecureLocalStore.appDirectoryName = "SynologyMonitor"
SecureLocalStore.serviceNamespace = "com.synologymonitor"
SecureLocalStore.legacyKeyProvider = {
    let seed = NSUserName() + ":com.synologymonitor.securelocalstore.v1"
    return SymmetricKey(data: SHA256.hash(data: Data(seed.utf8)))
}

guard let conn = CredentialStore.savedConnections().first,
      let password = CredentialStore.password(for: conn) else {
    print("no source connection/password"); exit(2)
}
let pin = TrustedCertificateStore.pinnedCertificateData(for: conn.host, port: conn.port)
print("source: \(conn.id) user=\(conn.username) pin=\(pin != nil)")

// 2) Destination: Photos app store (matches SynologyPhotosManagerApp config).
SecureLocalStore.appDirectoryName = "SynologyPhotosManager"
SecureLocalStore.serviceNamespace = "com.synokit"
SecureLocalStore.legacyKeyProvider = nil

CredentialStore.addOrUpdate(connection: conn, password: password)
CredentialStore.setSelectedConnectionID(conn.id)
if let pin { TrustedCertificateStore.pin(certificateData: pin, for: conn.host, port: conn.port) }

// Verify round-trip in the destination store.
let ok = CredentialStore.password(for: conn) == password
    && TrustedCertificateStore.pinnedCertificateData(for: conn.host, port: conn.port) != nil
print("seeded Photos store: password+pin readable=\(ok)")
exit(ok ? 0 : 1)
