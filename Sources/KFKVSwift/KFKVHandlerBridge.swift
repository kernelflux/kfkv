import Foundation
import KFKV

/// A Swift-friendly KFKV handler that bridges ObjC callbacks into closures.
/// Pass to `KFKVModule.init(handler:)` during service registration.
public final class KFKVHandlerBridge: NSObject, KFKVHandler {

    public typealias LogCallback = (KFKVLogLevel, String, Int, String, String) -> Void
    public typealias RecoveryCallback = (String) -> KFKVRecoverStrategic
    public typealias ChangeCallback = (String) -> Void

    public var onLog: LogCallback?
    public var onCRCFail: RecoveryCallback?
    public var onFileLengthError: RecoveryCallback?
    public var onContentChange: ChangeCallback?
    public var onContentLoaded: ChangeCallback?

    public init(
        onLog: LogCallback? = nil,
        onCRCFail: RecoveryCallback? = nil,
        onFileLengthError: RecoveryCallback? = nil,
        onContentChange: ChangeCallback? = nil,
        onContentLoaded: ChangeCallback? = nil
    ) {
        self.onLog = onLog
        self.onCRCFail = onCRCFail
        self.onFileLengthError = onFileLengthError
        self.onContentChange = onContentChange
        self.onContentLoaded = onContentLoaded
    }

    // MARK: - KFKVHandler

    public func onKFKVCRCCheckFail(_ mmapID: String) -> KFKVRecoverStrategic {
        onCRCFail?(mmapID) ?? .onErrorDiscard
    }

    public func onKFKVFileLengthError(_ mmapID: String) -> KFKVRecoverStrategic {
        onFileLengthError?(mmapID) ?? .onErrorDiscard
    }

    public func kfkvLog(with level: KFKVLogLevel, file: UnsafePointer<CChar>, line: Int32, func: UnsafePointer<CChar>, message: String) {
        onLog?(level, String(cString: file), Int(line), String(cString: `func`), message)
    }

    public func onKFKVContentChange(_ mmapID: String) {
        onContentChange?(mmapID)
    }

    public func onKFKVContentLoadSuccessfully(_ mmapID: String) {
        onContentLoaded?(mmapID)
    }

    /// A default handler that discards on error (default KFKV behavior) and logs via print.
    /// Safer than nil — nil means KFKV falls back to NSLog, which we typically don't want in production.
    public static var defaultBridge: KFKVHandlerBridge {
        KFKVHandlerBridge(
            onLog: { level, file, line, function, message in
                let levelStr: String
                switch level {
                case .info:  levelStr = "INFO"
                case .warning: levelStr = "WARN"
                case .error:  levelStr = "ERROR"
                case .debug:  levelStr = "DEBUG"
                case .none:   return
                @unknown default: levelStr = "UNKNOWN"
                }
                let filename = (file as NSString).lastPathComponent
                print("[KFKV][\(levelStr)] \(filename):\(line) \(message)")
            }
        )
    }
}
