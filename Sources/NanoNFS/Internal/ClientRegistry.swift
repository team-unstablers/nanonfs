import Foundation
import Atomics

// RFC 7530 §16.33-§16.35 — clientid lifecycle.
//
// SETCLIENTID:         client introduces itself with (verifier, owner string,
//                      callback program/addr). Server returns a clientid +
//                      setclientid_confirm verifier.
// SETCLIENTID_CONFIRM: client echoes both back, server commits the binding.
// RENEW:               client refreshes its lease.
//
// nanonfs's responsibility is purely bookkeeping — the user's `NFSServer`
// methods do not see clientids; we lazily map stateids/lockids back to a
// clientid when needed.

struct PendingClient: Sendable {
    var verifier:        UInt64
    var ownerName:       Data           // up to NFS4_OPAQUE_LIMIT
    var clientid:        UInt64
    var confirmVerifier: UInt64
    var callbackProgram: UInt32
    var callbackAddr:    String
}

struct ConfirmedClient: Sendable {
    var clientid:        UInt64
    var verifier:        UInt64
    var ownerName:       Data
    var lastRenewal:     Date
    var callbackProgram: UInt32
    var callbackAddr:    String
}

/// Holds clientid → confirmed-client mappings for the lifetime of the
/// listener. Pending records (post-SETCLIENTID, pre-CONFIRM) are kept in a
/// separate dictionary so a duplicate SETCLIENTID retransmission overwrites
/// the previous attempt rather than confirming it.
actor ClientRegistry {
    private var pending: [UInt64: PendingClient] = [:]   // keyed by clientid
    private var confirmed: [UInt64: ConfirmedClient] = [:]
    /// Maps owner-string → confirmed clientid for fast SETCLIENTID lookup.
    private var byOwner: [Data: UInt64] = [:]

    /// Atomic counter for clientid generation. Initialised with a random
    /// high bit so a fresh process can be distinguished from a previous one
    /// without persisting state across restarts.
    private let clientidCounter = ManagedAtomic<UInt64>(UInt64.random(in: 1...UInt64.max) | (1 << 32))
    private let confirmCounter  = ManagedAtomic<UInt64>(UInt64.random(in: 1...UInt64.max))

    func setclientid(verifier: UInt64,
                     ownerName: Data,
                     callbackProgram: UInt32,
                     callbackAddr: String) -> (clientid: UInt64, confirmVerifier: UInt64) {
        // Mint a fresh clientid + confirm verifier. We do not yet correlate
        // re-issues to the same logical owner — RFC 7530 §16.33.5 allows the
        // server to either reuse or re-issue when the owner string matches.
        let clientid = clientidCounter.wrappingIncrementThenLoad(ordering: .relaxed)
        let confirm  = confirmCounter.wrappingIncrementThenLoad(ordering: .relaxed)
        pending[clientid] = PendingClient(
            verifier: verifier,
            ownerName: ownerName,
            clientid: clientid,
            confirmVerifier: confirm,
            callbackProgram: callbackProgram,
            callbackAddr: callbackAddr
        )
        return (clientid, confirm)
    }

    enum ConfirmResult: Sendable, Equatable {
        case ok
        case staleClientid     // NFS4ERR_STALE_CLIENTID
        case clidInUse         // NFS4ERR_CLID_INUSE
    }

    func setclientidConfirm(clientid: UInt64, confirmVerifier: UInt64) -> ConfirmResult {
        guard let p = pending[clientid] else {
            // Maybe the binding is already confirmed (idempotent retry).
            if let existing = confirmed[clientid] {
                if existing.clientid == clientid {
                    return .ok
                }
            }
            return .staleClientid
        }
        guard p.confirmVerifier == confirmVerifier else {
            return .staleClientid
        }
        // If a previous confirmation existed under the same owner string but
        // a different verifier, RFC says NFS4ERR_CLID_INUSE.
        if let priorClid = byOwner[p.ownerName],
           let prior = confirmed[priorClid],
           prior.verifier != p.verifier {
            return .clidInUse
        }
        // If a previous confirmation existed and we are *re*-confirming with
        // the same verifier, drop the old binding — RFC 7530 §16.34.5.
        if let priorClid = byOwner[p.ownerName] {
            confirmed.removeValue(forKey: priorClid)
        }
        pending.removeValue(forKey: clientid)
        confirmed[clientid] = ConfirmedClient(
            clientid: clientid,
            verifier: p.verifier,
            ownerName: p.ownerName,
            lastRenewal: Date(),
            callbackProgram: p.callbackProgram,
            callbackAddr: p.callbackAddr
        )
        byOwner[p.ownerName] = clientid
        return .ok
    }

    enum RenewResult: Sendable, Equatable {
        case ok
        case stale
        case expired
    }

    func renew(clientid: UInt64, leaseSeconds: TimeInterval) -> RenewResult {
        guard var rec = confirmed[clientid] else { return .stale }
        let now = Date()
        if now.timeIntervalSince(rec.lastRenewal) > leaseSeconds * 2 {
            // Past 2× lease window — treat as expired and reap.
            confirmed.removeValue(forKey: clientid)
            byOwner.removeValue(forKey: rec.ownerName)
            return .expired
        }
        rec.lastRenewal = now
        confirmed[clientid] = rec
        return .ok
    }

    func isConfirmed(_ clientid: UInt64) -> Bool {
        confirmed[clientid] != nil
    }
}
