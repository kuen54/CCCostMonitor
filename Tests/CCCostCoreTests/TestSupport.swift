import Foundation
@testable import CCCostCore

// Shared fixture helpers. ALL fixtures are synthetic — never paste real
// `analyze_usage.py --json` output here (it contains real project paths).

/// Construct a local-time Date from explicit Gregorian components via
/// AppDate's pinned calendar. Tests never use bare Date() literals.
func makeDate(_ year: Int, _ month: Int, _ day: Int,
              hour: Int = 12, minute: Int = 0) -> Date {
    var c = DateComponents()
    c.year = year; c.month = month; c.day = day
    c.hour = hour; c.minute = minute
    guard let d = AppDate.gregorian.date(from: c) else {
        fatalError("invalid test date \(year)-\(month)-\(day)")
    }
    return d
}

func makeModel(_ cls: ModelClass, cost: Double, messages: Int,
               input: Int, output: Int,
               cacheRead: Int = 0, cacheWrite: Int = 0) -> ModelUsage {
    ModelUsage(id: cls.rawValue, name: cls.displayName,
               cost: cost, messages: messages,
               inputTokens: input, outputTokens: output,
               cacheRead: cacheRead, cacheWrite: cacheWrite)
}

func makeDay(_ dateString: String, cost: Double, totalTokens: Int,
             models: [ModelUsage]) -> DailyUsage {
    DailyUsage(dateString: dateString,
               day: Int(dateString.suffix(2)) ?? 0,
               cost: cost, totalTokens: totalTokens, models: models)
}

/// Parse a synthetic JSON string into the `[String: Any]` shape the parsers
/// consume (same JSONSerialization path the app uses on script stdout).
func jsonDict(_ s: String) -> [String: Any] {
    guard let data = s.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data),
          let dict = obj as? [String: Any] else {
        fatalError("test fixture is not valid JSON")
    }
    return dict
}

/// Double equality with tolerance (swift-testing has no XCTAssertEqual-accuracy).
func approx(_ a: Double, _ b: Double, _ epsilon: Double = 1e-9) -> Bool {
    abs(a - b) < epsilon
}
