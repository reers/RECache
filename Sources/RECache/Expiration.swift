//
//  Copyright © 2025 reers.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import Foundation

/// Expiration policy for a cached entry.
///
/// Expiration is evaluated against the entry's **write time**. Calling
/// `set(_:forKey:expiration:)` always resets the write time, which
/// effectively refreshes the expiration. Reading via `value(forKey:)` does
/// **not** refresh the write time — LRU ordering and expiration are
/// independent axes.
public enum Expiration: Sendable, Hashable {
    /// The entry never expires.
    case never

    /// The entry expires `TimeInterval` seconds after its write time.
    case seconds(TimeInterval)

    /// The entry expires `days` days after its write time.
    ///
    /// Equivalent to ``seconds(_:)`` with `Double(days) * 86_400`.
    case days(Int)

    /// The entry expires at the given absolute `Date`.
    case date(Date)

    /// Absolute expiration date given a reference write time.
    public func expirationDate(from writeDate: Date) -> Date? {
        switch self {
        case .never:
            return nil
        case .seconds(let interval):
            return writeDate.addingTimeInterval(interval)
        case .days(let days):
            return writeDate.addingTimeInterval(TimeInterval(days) * 86_400)
        case .date(let date):
            return date
        }
    }

    /// Whether an entry written at `writeDate` is already expired at `now`.
    public func isExpired(writtenAt writeDate: Date, now: Date = Date()) -> Bool {
        guard let expiration = expirationDate(from: writeDate) else { return false }
        return now >= expiration
    }
}
