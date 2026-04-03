//
//  CodeMatchChallengeCore.swift
//  TubCompanion
//
//  Shared math/helpers for code-match unlock challenges.
//

import Foundation

enum CodeMatchChallengeCore {
    static let accessPassword = "THETUB"

    static let baseTokens = [
        "7F", "A2", "D0", "3C",
        "B9", "11", "EF", "42",
        "9A", "C7", "55", "0D",
        "6E", "14", "8B", "F1"
    ]

    static func buildStrip(roundIndex: Int, targetToken: String) -> (tokens: [String], targetSlotIndex: Int) {
        guard !baseTokens.isEmpty else { return ([targetToken], 0) }

        let safeRound = max(0, roundIndex)
        let rotation = (safeRound * 3) % baseTokens.count
        var rotated: [String] = []
        rotated.reserveCapacity(baseTokens.count)
        for index in 0..<baseTokens.count {
            rotated.append(baseTokens[(index + rotation) % baseTokens.count])
        }

        let targetSlotIndex = min(rotated.count - 1, 2 + safeRound * 3)
        rotated[targetSlotIndex] = targetToken.uppercased()
        return (rotated, targetSlotIndex)
    }

    static func circularDistance(from: Int, to: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let direct = abs(from - to)
        return min(direct, count - direct)
    }

    static func timerInterval(stripSpeed: Double) -> TimeInterval {
        max(0.05, 1.0 / max(1.0, stripSpeed))
    }

    static func isPasswordValid(_ rawValue: String) -> Bool {
        normalizedPassword(rawValue) == accessPassword
    }

    static func normalizedPassword(_ rawValue: String) -> String {
        String(rawValue.uppercased().filter(\.isLetter).prefix(accessPassword.count))
    }

    static func isMatchWithLateGrace(
        activeIndex: Int,
        targetIndex: Int,
        tokenCount: Int,
        windowTolerance: Int,
        lastTickAt: Date?,
        now: Date,
        tickInterval: TimeInterval
    ) -> Bool {
        let boundedTolerance = max(0, windowTolerance)
        let distanceNow = circularDistance(from: activeIndex, to: targetIndex, count: tokenCount)
        if distanceNow <= boundedTolerance {
            return true
        }

        guard let lastTickAt else { return false }
        let graceWindow = min(0.095, max(0.03, tickInterval * 0.72))
        guard now.timeIntervalSince(lastTickAt) <= graceWindow else { return false }
        guard tokenCount > 0 else { return false }

        let previousIndex = (activeIndex - 1 + tokenCount) % tokenCount
        let distancePrevious = circularDistance(from: previousIndex, to: targetIndex, count: tokenCount)
        return distancePrevious <= boundedTolerance
    }
}
