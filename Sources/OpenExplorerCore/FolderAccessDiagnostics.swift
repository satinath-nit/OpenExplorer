import Foundation

public enum FolderAccessDiagnostics {
    public static let fullDiskAccessSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
    )!

    public static func isPermissionDenied(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            let permissionCodes: Set<Int> = [
                CocoaError.fileReadNoPermission.rawValue,
                CocoaError.fileWriteNoPermission.rawValue
            ]
            if permissionCodes.contains(nsError.code) { return true }
        }

        if nsError.domain == NSPOSIXErrorDomain {
            let permissionCodes: Set<Int> = [
                Int(POSIXErrorCode.EACCES.rawValue),
                Int(POSIXErrorCode.EPERM.rawValue)
            ]
            if permissionCodes.contains(nsError.code) { return true }
        }

        if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? Error,
           (underlyingError as NSError) !== nsError {
            return isPermissionDenied(underlyingError)
        }
        return false
    }
}
