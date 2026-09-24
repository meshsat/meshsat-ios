// Mirrors ratelimit/TokenBucket.kt (the Bridge's internal/ratelimit): a token bucket, thread-safe.
import Foundation

public final class TokenBucket: @unchecked Sendable {
    private let lock = NSLock()
    private let maxTokens: Double
    private let refillRate: Double
    private var tokens: Double
    private var lastRefill: Double
    private let now: @Sendable () -> Double

    /// `maxTokens` is the burst capacity, `refillRate` tokens per second. `now` is seconds on
    /// a monotonic clock, injectable for tests.
    public init(
        maxTokens: Double, refillRate: Double,
        now: @escaping @Sendable () -> Double = { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
    ) {
        self.maxTokens = maxTokens
        self.refillRate = refillRate
        self.tokens = maxTokens
        self.now = now
        self.lastRefill = now()
    }

    /// Take a token if one is there.
    public func allow() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        refill()
        if tokens >= 1.0 {
            tokens -= 1.0
            return true
        }
        return false
    }

    /// Current token count (for monitoring).
    public func tokenCount() -> Double {
        lock.lock()
        defer { lock.unlock() }
        refill()
        return tokens
    }

    private func refill() {
        let t = now()
        let elapsed = t - lastRefill
        lastRefill = t
        tokens = min(maxTokens, tokens + elapsed * refillRate)
    }

    /// Global limiter for injecting external messages into the mesh: 6 a minute (1 per 10 s).
    public static func meshInjectionLimiter() -> TokenBucket { TokenBucket(maxTokens: 6, refillRate: 0.1) }

    /// Per-rule limiter, or nil when the rule has none.
    public static func ruleLimiter(perWindow: Int, windowSeconds: Int) -> TokenBucket? {
        if perWindow <= 0 || windowSeconds <= 0 { return nil }
        return TokenBucket(maxTokens: Double(perWindow), refillRate: Double(perWindow) / Double(windowSeconds))
    }
}
