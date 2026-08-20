import Testing
import Foundation
@testable import kebab

/// The account-deletion Storage purge decides teardown on ABSENCE, never on
/// how many objects a DELETE reported affecting. Storage returns the same
/// short list whether RLS filtered the delete or the object was simply already
/// gone, so these pin the two opposite meanings apart.
@Suite("Account storage purge")
struct AccountPurgeTests {

    private func paths(_ names: [String], uid: String = "uid") -> Set<String> {
        Set(names.map { "\(uid)/\($0)" })
    }

    @Test("Nothing left in the bucket is a clean purge")
    func everythingAbsentPasses() {
        let targeted = paths(["a.jpg", "b.jpg", "c.jpg"])
        #expect(AuthViewModel.stillPresent(targeted: targeted, presentInBucket: []).isEmpty)
    }

    /// The wedge this model exists to prevent: a retry after a partial (or
    /// even a fully successful) purge re-targets paths that are already gone.
    /// Storage does not report those as removed, so a count-based gate would
    /// fail forever and the account could never be deleted.
    @Test("Already-absent objects count as purged, so a retry is not wedged")
    func retryAfterPartialSuccessPasses() {
        let targeted = paths(["a.jpg", "b.jpg", "c.jpg", "d.jpg"])
        // First attempt removed a.jpg and b.jpg; the retry re-targets all four
        // and this time the DELETE reports removing only the remaining two.
        let stillThere = paths(["c.jpg", "d.jpg"])
        #expect(AuthViewModel.stillPresent(targeted: targeted, presentInBucket: stillThere) == stillThere)
        // Once the retry clears those, the same targeted set verifies clean.
        #expect(AuthViewModel.stillPresent(targeted: targeted, presentInBucket: []).isEmpty)
    }

    @Test("A single surviving object blocks teardown")
    func onePresentObjectFails() {
        let targeted = paths(["a.jpg", "b.jpg", "c.jpg"])
        let survivor = paths(["b.jpg"])
        let result = AuthViewModel.stillPresent(targeted: targeted, presentInBucket: survivor)
        #expect(result == survivor)
        #expect(!result.isEmpty)
    }

    /// The silent-RLS-filter case that started all of this: the DELETE
    /// "succeeded" with an empty list and removed nothing.
    @Test("A delete that removed nothing at all is a failure, not a success")
    func removedNothingFails() {
        let targeted = paths(["a.jpg", "b.jpg"])
        #expect(AuthViewModel.stillPresent(targeted: targeted, presentInBucket: targeted) == targeted)
    }

    @Test("An account with no uploaded objects purges trivially")
    func zeroObjectAccount() {
        #expect(AuthViewModel.stillPresent(targeted: [], presentInBucket: []).isEmpty)
        // Unrelated objects in the bucket are not this account's problem.
        #expect(AuthViewModel.stillPresent(targeted: [], presentInBucket: paths(["x.jpg"])).isEmpty)
    }

    @Test("Objects belonging to other users are never counted against the purge")
    func otherUsersObjectsIgnored() {
        let targeted = paths(["a.jpg"], uid: "mine")
        let others = paths(["a.jpg", "b.jpg"], uid: "theirs")
        #expect(AuthViewModel.stillPresent(targeted: targeted, presentInBucket: others).isEmpty)
    }

    /// 250 objects spans three removal batches (100/100/50). Verified as set
    /// logic rather than by uploading 250 real files.
    @Test("A multi-batch account verifies as one set, batch boundaries and all")
    func multiBatchAccount() {
        let names = (0..<250).map { "obj-\($0).jpg" }
        let targeted = paths(names)
        #expect(targeted.count == 250)

        // First attempt: batch 1 (the first 100 by our own ordering) landed,
        // the rest did not.
        let removedFirst = paths(Array(names[0..<100]))
        let remainder = targeted.subtracting(removedFirst)
        #expect(AuthViewModel.stillPresent(targeted: targeted, presentInBucket: remainder) == remainder)
        #expect(remainder.count == 150)

        // Retry clears the remainder; the already-absent first 100 do not
        // resurrect the failure.
        #expect(AuthViewModel.stillPresent(targeted: targeted, presentInBucket: []).isEmpty)
    }

    /// Batch slicing must cover every path exactly once, including the short
    /// final batch — the arithmetic the purge loop uses.
    @Test("Batching covers every targeted path exactly once")
    func batchingCoversEveryPath() {
        for total in [0, 1, 99, 100, 101, 250] {
            let all = (0..<total).map { "uid/obj-\($0).jpg" }
            var index = 0
            var seen: [String] = []
            while index < all.count {
                seen.append(contentsOf: all[index..<min(index + 100, all.count)])
                index += 100
            }
            #expect(seen.count == total)
            #expect(Set(seen) == Set(all))
        }
    }
}
