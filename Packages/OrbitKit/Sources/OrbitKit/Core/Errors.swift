import Foundation

public enum OrbitError: LocalizedError, Equatable {
    case unsupported(String)
    case missingTool(String)
    case failed(String)
    case invalidInput(String)
    case passwordRequired
    case wrongPassword

    public var errorDescription: String? {
        switch self {
        case .unsupported(let what): return "Not supported: \(what)"
        case .missingTool(let what): return what
        case .failed(let why): return why
        case .invalidInput(let why): return why
        case .passwordRequired: return "This file is password-protected."
        case .wrongPassword: return "The password is incorrect."
        }
    }
}
