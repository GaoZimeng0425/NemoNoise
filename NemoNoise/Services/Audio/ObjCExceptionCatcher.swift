import Foundation

/// Runs `body`, converting any Objective-C `NSException` it raises into a thrown
/// Swift error. Swift's `do/catch` cannot catch `NSException` — it unwinds to
/// `abort()`. `-[AVAudioNode installTapOnBus:...]` raises one for an
/// invalid/transitional format during a Bluetooth A2DP↔HFP route switch, which
/// would otherwise crash the app. Bridged through `NNExceptionCatcher` (Obj-C).
func catchingObjCException(_ body: () -> Void) throws {
    try NNExceptionCatcher.attempt(body)
}
