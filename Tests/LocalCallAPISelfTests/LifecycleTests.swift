import Foundation

func testEndEvidenceAfterInitialization() throws {
    let results: [(CallEndReason, CallEndEvidence)] = [
        (.localHangup, CallEndEvidence(source: .localAction)),
        (.unknown, CallEndEvidence(source: .callListEmpty)),
        (.unknown, .modemResult("NO CARRIER")),
        (.noAnswer, .modemResult("NO ANSWER")),
        (.busy, .modemResult("BUSY")),
        (.failed, CallEndEvidence(source: .internalFailure)),
        (.deviceDisconnected, CallEndEvidence(source: .deviceDisconnected)),
    ]
    for (reason, evidence) in results {
        var call = CallSnapshot(phase: .ending, direction: .outgoing, number: "123",
                                voiceOverUSBSupported: true, audioActive: true, muted: true,
                                startedAt: Date(), lastError: "stale", mediaCleanupPending: true)
        call.recordEnd(reason, evidence: evidence)
        // Recovery can first encounter a busy runtime, then complete a retry.
        call.resetForInitialization(phase: .unavailable, voiceOverUSBSupported: false,
                                    lastError: "runtime busy", controlInterfaceBusy: true)
        expect(call.lastEndReason == reason && call.lastEndEvidence == evidence,
               "Failed initialization erased the call result")
        expect(call.lastError == "runtime busy" && call.controlInterfaceBusy,
               "Initialization diagnostics were not applied")
        call.resetForInitialization(phase: .idle, voiceOverUSBSupported: true)
        expect(call.phase == .idle && call.canDial && call.lastError == nil && !call.controlInterfaceBusy,
               "Initialization retry did not restore readiness")
        expect(call.number == nil && call.direction == nil && call.startedAt == nil &&
               !call.audioActive && !call.muted && !call.mediaCleanupPending,
               "Initialization retained active call/media state")
        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            LocalCallAPIStatus(call: call, isChangingCall: false))) as! [String: Any]
        expect(body["lastEndReason"] as? String == reason.rawValue,
               "API lost the end reason after recovery/retry")
        let encodedEvidence = body["lastEndEvidence"] as! [String: Any]
        expect(encodedEvidence["source"] as? String == evidence.source.rawValue &&
               encodedEvidence["code"] as? String == evidence.code,
               "API lost the end evidence after recovery/retry")
        call.clearEnd()
        call.resetForInitialization(phase: .idle, voiceOverUSBSupported: true)
        expect(call.lastEndReason == nil && call.lastEndEvidence == nil,
               "A new call's reset resurrected an older result")
    }
}

@MainActor
func testTerminationCancellation() async {
    let coordinator = AppTerminationCoordinator(timeout: 0.05)
    var cleanups = 0
    var cancellations = 0
    var replies = 0
    var completeCleanup: ((Bool) -> Void)?
    coordinator.cleanup = { complete in
        cleanups += 1
        completeCleanup = complete
    }
    coordinator.onTerminationCancelled = { cancellations += 1 }

    let failed = await withCheckedContinuation { reply in
        expect(coordinator.beginTermination { result in
            replies += 1
            reply.resume(returning: result)
        } == .terminateLater, "Cleanup must defer termination")
        expect(coordinator.beginTermination { _ in fatalError("Duplicate quit replied") } == .terminateLater,
               "An overlapping quit must remain deferred")
        expect(cleanups == 1, "An overlapping quit repeated cleanup")
        completeCleanup?(false)
        completeCleanup?(false)
    }
    expect(!failed && cancellations == 1 && replies == 1,
           "Failed cleanup did not restore services exactly once")

    // The original timeout must not cancel a later successful attempt.
    let succeeded = await withCheckedContinuation { reply in
        _ = coordinator.beginTermination { result in
            replies += 1
            reply.resume(returning: result)
        }
        completeCleanup?(true)
    }
    try? await Task.sleep(nanoseconds: 100_000_000)
    expect(succeeded && cancellations == 1 && replies == 2 && cleanups == 2,
           "Successful termination or a stale timeout restarted services")

    let timedOut = await withCheckedContinuation { reply in
        _ = coordinator.beginTermination { result in
            replies += 1
            reply.resume(returning: result)
        }
    }
    expect(!timedOut && cancellations == 2 && replies == 3,
           "Termination timeout did not restore services")
    completeCleanup?(true)
    completeCleanup?(false)
    try? await Task.sleep(nanoseconds: 20_000_000)
    expect(cancellations == 2 && replies == 3, "Late cleanup repeated cancellation/reply")
    print("Call result initialization and termination cancellation tests passed")
}
