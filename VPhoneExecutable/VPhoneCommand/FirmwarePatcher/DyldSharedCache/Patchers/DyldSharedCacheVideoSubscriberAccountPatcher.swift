import Foundation
import VPhonePatchKit

/// Retain VideoSubscriberAccount's legacy log-and-reject behavior for SDK-linked
/// misuse. Entitlement checks and subscription validation still run unchanged.
public enum DyldSharedCacheVideoSubscriberAccountPatcher {
    public static let patchID = "dyld-cfw-video_subscriber_account"
    public static let imagePath = "/System/Library/Frameworks/VideoSubscriberAccount.framework/VideoSubscriberAccount"
    public static let symbol = "-[VSSubscriptionRegistrationCenter _shouldRaiseExceptionsForMisuse]"

    static func replacement(for original: Data, at address: UInt64) throws -> Data {
        _ = try DyldSharedCacheCameraPatcher.classifyPrologue(
            original, at: address, symbol: symbol, returning: 0,
            disassembler: ARM64Disassembler(), force: false, log: nil,
        )
        return try DyldSharedCacheCameraPatcher.replacement(returning: 0)
    }

    public static func patch(
        chunksDirectory: URL,
        dryRun: Bool = false,
        captureUndo: Bool = false,
        onUndo: ((DyldSharedCacheUndoLog) -> Void)? = nil,
        log: ((String) -> Void)? = nil,
    ) throws {
        let chunks = try DyldSharedCacheChunkSet(directory: chunksDirectory, captureUndo: captureUndo)
        defer {
            if captureUndo, let undo = chunks.takeUndoLog() { onUndo?(undo) }
        }
        let resolver = try DyldSharedCacheSymbolResolver(mainCacheURL: chunks.mainCacheURL)
        try resolver.requireLocalSymbols()
        let address = try resolver.address(of: symbol, inImage: imagePath)
        let original = try chunks.bytesAtVMA(address, length: 8)
        let bytes = try replacement(for: original, at: address)
        log?("  \(symbol) @ 0x\(String(address, radix: 16)): \(original.hex) -> \(bytes.hex)")
        guard !dryRun else { return }
        try chunks.write(at: address, bytes)
        _ = try DyldSharedCacheCodeSignature.reattestRecordedWrites(in: chunks, log: log)
        guard try chunks.bytesAtVMA(address, length: bytes.count) == bytes else {
            throw PatcherError.patchVerificationFailed("VideoSubscriberAccount policy read-back failed")
        }
    }
}
