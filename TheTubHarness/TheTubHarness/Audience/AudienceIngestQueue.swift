//
//  AudienceIngestQueue.swift
//  TheTubHarness
//
//  Local file-backed queue for audience audio contributions.
//  Manages state machine: inbox → cooldown → normalizing → transient_splicing → approved/rejected
//

import Foundation

class AudienceIngestQueue {
    private let queueDirectoryURL: URL
    private let queueLock = NSLock()
    private var contributions: [String: AudienceAudioContribution] = [:]
    
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    
    init(baseDirectory: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]) {
        self.queueDirectoryURL = baseDirectory.appendingPathComponent("audience_queue")
        try? FileManager.default.createDirectory(at: queueDirectoryURL, withIntermediateDirectories: true)
        loadQueueState()
    }
    
    // MARK: - Queue Operations
    
    func enqueue(_ contribution: AudienceAudioContribution) {
        queueLock.lock()
        defer { queueLock.unlock() }
        
        contributions[contribution.contributionId] = contribution
        persistContribution(contribution)
        print("Queued audio contribution: \(contribution.contributionId) (\(contribution.state))")
    }
    
    func getContributions(with state: AudioContributionState) -> [AudienceAudioContribution] {
        queueLock.lock()
        defer { queueLock.unlock() }
        
        return contributions.values.filter { $0.state == state }
    }
    
    func transitionState(contributionId: String, to newState: AudioContributionState, reason: String? = nil) {
        queueLock.lock()
        defer { queueLock.unlock() }
        
        guard var contribution = contributions[contributionId] else { return }
        
        var updated = contribution
        updated.state = newState
        updated.stateTransitionAt = Date()
        if let reason = reason, newState == .rejected {
            updated.rejectionReason = reason
        }
        
        contributions[contributionId] = updated
        persistContribution(updated)
        print("Transitioned \(contributionId) from \(contribution.state) to \(newState)")
    }
    
    func processQueue() {
        queueLock.lock()
        defer { queueLock.unlock() }
        
        // Move items through state machine
        let inboxItems = contributions.values.filter { $0.state == .inbox }
        for contribution in inboxItems {
            transitionState(contributionId: contribution.contributionId, to: .cooldown)
        }
        
        let cooldownItems = contributions.values.filter { $0.state == .cooldown }
        for contribution in cooldownItems {
            if Date().timeIntervalSince(contribution.stateTransitionAt) > 2.0 {
                transitionState(contributionId: contribution.contributionId, to: .normalizing)
            }
        }
        
        let normalizingItems = contributions.values.filter { $0.state == .normalizing }
        for contribution in normalizingItems {
            if Date().timeIntervalSince(contribution.stateTransitionAt) > 1.0 {
                transitionState(contributionId: contribution.contributionId, to: .transientSplicing)
            }
        }
        
        let splicingItems = contributions.values.filter { $0.state == .transientSplicing }
        for contribution in splicingItems {
            if Date().timeIntervalSince(contribution.stateTransitionAt) > 1.5 {
                // Stub: real impl would evaluate moderation
                let approved = Bool.random() // Stub random approval for demo
                let newState: AudioContributionState = approved ? .approved : .rejected
                transitionState(
                    contributionId: contribution.contributionId,
                    to: newState,
                    reason: approved ? nil : "Random stub rejection"
                )
            }
        }
    }
    
    // MARK: - Persistence
    
    private func persistContribution(_ contribution: AudienceAudioContribution) {
        let fileURL = queueDirectoryURL
            .appendingPathComponent(contribution.contributionId)
            .appendingPathExtension("json")
        
        do {
            let data = try encoder.encode(contribution)
            try data.write(to: fileURL)
        } catch {
            print("Failed to persist contribution \(contribution.contributionId): \(error)")
        }
    }
    
    private func loadQueueState() {
        do {
            let files = try FileManager.default.contentsOfDirectory(at: queueDirectoryURL, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file),
                   let contribution = try? decoder.decode(AudienceAudioContribution.self, from: data) {
                    contributions[contribution.contributionId] = contribution
                }
            }
            print("Loaded \(contributions.count) contributions from persistent queue")
        } catch {
            print("Failed to load queue state: \(error)")
        }
    }
    
    func clearProcessed() {
        queueLock.lock()
        defer { queueLock.unlock() }
        
        let approved = contributions.values.filter { $0.state == .approved }
        let rejected = contributions.values.filter { $0.state == .rejected }
        
        for contribution in approved + rejected {
            contributions.removeValue(forKey: contribution.contributionId)
            deleteContributionFile(contribution.contributionId)
        }
        
        print("Cleared \(approved.count + rejected.count) processed contributions")
    }
    
    private func deleteContributionFile(_ contributionId: String) {
        let fileURL = queueDirectoryURL
            .appendingPathComponent(contributionId)
            .appendingPathExtension("json")
        try? FileManager.default.removeItem(at: fileURL)
    }
}
