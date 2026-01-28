import Foundation
import CloudKit

enum AppErrorMapper {
    static func message(for error: Error) -> String {
        if let serviceError = error as? CloudKitSpotService.ServiceError {
            return serviceError.localizedDescription
        }

        if let ck = error as? CKError {
            switch ck.code {
            case .notAuthenticated:
                return "Je bent niet ingelogd in iCloud. Log in op je iPhone via Instellingen → Apple ID → iCloud."
            case .permissionFailure:
                return "Geen toestemming voor CloudKit. Zet iCloud → CloudKit aan bij Signing & Capabilities en kies een container."
            case .networkUnavailable, .networkFailure:
                return "Geen netwerkverbinding. Probeer het opnieuw wanneer je internet hebt."
            case .zoneNotFound:
                return "CloudKit zone niet gevonden. Controleer of je CloudKit container bestaat in de Apple Developer console."
            default:
                break
            }
        }

        return "Er ging iets mis: \(error.localizedDescription)"
    }
}
