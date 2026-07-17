import Foundation
import SynoKit

/// Photos-specific error mapping. Kept out of SynoKit because these numeric
/// codes are specific to the SYNO.Foto.* APIs (see spike/FINDINGS.md) — the
/// same numbers mean different things in other DSM APIs.
public enum FotoError: Error, LocalizedError {
    case invalidParameter        // 600
    case parameterCondition      // 120
    case methodNotFound          // 103
    case server(code: Int)
    case notConfigured           // feature awaiting API params (e.g. sharing)

    public static func from(_ code: Int) -> Error {
        // Session/auth codes stay as SynoKit's typed errors so re-auth can kick in.
        if SynologyAPIError.sessionErrorCodes.contains(code) {
            return SynologyAPIError.sessionExpired
        }
        switch code {
        case 600: return FotoError.invalidParameter
        case 120: return FotoError.parameterCondition
        case 103: return FotoError.methodNotFound
        default: return FotoError.server(code: code)
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidParameter: return "잘못된 요청 파라미터입니다."
        case .parameterCondition: return "파라미터 조건이 맞지 않습니다."
        case .methodNotFound: return "지원하지 않는 메서드입니다."
        case .server(let code): return "Foto 서버 오류 (코드: \(code))."
        case .notConfigured: return "공유 기능은 아직 설정 중입니다 (웹 요청 캡처 후 활성화)."
        }
    }
}
