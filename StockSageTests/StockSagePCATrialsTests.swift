import Testing
import Foundation
@testable import StockSage

// PCA effective-trials (external-report item 8, owner-signed 2026-07-28).
// Every expectation below is hand-derived from linear algebra, never read back from the code.

@Suite("PCA effective trials")
struct StockSagePCATrialsTests {

    typealias P = StockSagePCATrials

    // MARK: eigenvalues — hand-checkable 2x2 and 3x3 cases

    @Test("Jacobi returns the known eigenvalues of small symmetric matrices")
    func jacobiEigenvaluesAreCorrect() {
        // [[1, r], [r, 1]] has eigenvalues 1±r. For r = 0.6 → {1.6, 0.4}.
        let e2 = P.symmetricEigenvalues([[1, 0.6], [0.6, 1]]).sorted(by: >)
        #expect(abs(e2[0] - 1.6) < 1e-9)
        #expect(abs(e2[1] - 0.4) < 1e-9)

        // Identity → all eigenvalues 1.
        let eI = P.symmetricEigenvalues([[1, 0, 0], [0, 1, 0], [0, 0, 1]])
        #expect(eI.allSatisfy { abs($0 - 1) < 1e-9 })

        // All-ones 3x3 correlation (perfect collinearity) → {3, 0, 0}: one component holds
        // every bit of variance, which is the whole point of the effective-trials idea.
        let eOnes = P.symmetricEigenvalues([[1, 1, 1], [1, 1, 1], [1, 1, 1]]).sorted(by: >)
        #expect(abs(eOnes[0] - 3) < 1e-9)
        #expect(abs(eOnes[1]) < 1e-9)
        #expect(abs(eOnes[2]) < 1e-9)

        // Eigenvalues sum to the trace, always — a cheap invariant on an arbitrary symmetric input.
        let m: [[Double]] = [[2, -0.5, 0.25], [-0.5, 1.5, 0.75], [0.25, 0.75, 3]]
        let sum = P.symmetricEigenvalues(m).reduce(0, +)
        #expect(abs(sum - (2 + 1.5 + 3)) < 1e-9)
    }

    // MARK: correlation matrix

    @Test("correlation matrix is unit-diagonal, symmetric, and exact on a known pair")
    func correlationMatrixIsCorrect() throws {
        // y = 2x + 1 is a perfect positive linear map ⇒ r = 1 exactly.
        let x: [Double] = [1, 2, 3, 4, 5]
        let y = x.map { 2 * $0 + 1 }
        let z = x.map { -$0 }                      // perfect negative ⇒ r = −1
        let c = try #require(P.correlationMatrix([x, y, z]))
        #expect(abs(c[0][0] - 1) < 1e-12)
        #expect(abs(c[0][1] - 1) < 1e-12)
        #expect(abs(c[0][2] + 1) < 1e-12)
        #expect(abs(c[1][2] + 1) < 1e-12)
        #expect(abs(c[0][1] - c[1][0]) < 1e-12)    // symmetric
    }

    @Test("a constant stream has no correlation — nil, never a fabricated number")
    func constantStreamReturnsNil() {
        #expect(P.correlationMatrix([[1, 1, 1, 1], [1, 2, 3, 4]]) == nil)
        #expect(P.effectiveTrials(returnStreams: [[1, 1, 1, 1], [1, 2, 3, 4]]) == nil)
    }

    // MARK: effective trials — the number that actually reaches the DSR

    @Test("perfectly collinear variants collapse to ONE effective trial")
    func collinearVariantsCollapse() {
        // Three "different" strategies that are really the same idea rescaled: correlation
        // matrix is all ones ⇒ eigenvalues {3,0,0} ⇒ first component alone is 3/3 = 100% ≥ 95%.
        let base: [Double] = [0.01, -0.02, 0.03, 0.005, -0.01, 0.02]
        let streams = [base, base.map { $0 * 2 }, base.map { $0 * 0.5 }]
        #expect(P.effectiveTrials(returnStreams: streams) == 1)
    }

    @Test("orthogonal variants each count as their own trial")
    func independentVariantsCountSeparately() {
        // Two exactly-uncorrelated streams: correlation matrix = I ⇒ eigenvalues {1,1};
        // the first component explains only 50%, so 95% needs BOTH ⇒ 2.
        // Hand-built orthogonal pair (both zero-mean, dot product = 0):
        //   a = [ 1, -1,  1, -1],  b = [ 1,  1, -1, -1]  → Σ a_i·b_i = 1 −1 −1 +1 = 0
        let a: [Double] = [1, -1, 1, -1]
        let b: [Double] = [1, 1, -1, -1]
        #expect(P.effectiveTrials(returnStreams: [a, b]) == 2)
    }

    @Test("a duplicated variant does not inflate the trial count")
    func duplicateDoesNotInflate() {
        // Three streams where two are identical and one is orthogonal: the honest answer is 2
        // independent ideas, not 3. This is exactly the report's collinearity concern.
        let a: [Double] = [1, -1, 1, -1]
        let b: [Double] = [1, 1, -1, -1]
        let three = P.effectiveTrials(returnStreams: [a, a, b])
        #expect(three == 2, "duplicate + orthogonal should be 2 effective trials, got \(String(describing: three))")
    }

    @Test("effective trials never exceeds the stream count and never fabricates from thin input")
    func boundsAndGuards() {
        let a: [Double] = [1, -1, 1, -1]
        let b: [Double] = [1, 1, -1, -1]
        let n = P.effectiveTrials(returnStreams: [a, b])
        #expect(n != nil && n! >= 1 && n! <= 2)
        #expect(P.effectiveTrials(returnStreams: []) == nil)          // nothing to correlate
        #expect(P.effectiveTrials(returnStreams: [a]) == nil)         // one variant is not a sweep
        #expect(P.effectiveTrials(returnStreams: [a, [1, -1]]) == nil) // ragged lengths
    }

    @Test("a stricter variance target demands at least as many components")
    func targetMonotonicity() {
        // Partially correlated pair: r = 0.6 ⇒ eigenvalues {1.6, 0.4}. First component alone is
        // 1.6/2 = 80%: enough for a 0.75 target, NOT enough for 0.95 (which needs both).
        // Streams built to have exactly r = 0.6 are fiddly, so assert the property instead:
        // the count under a stricter target can never be smaller.
        let x: [Double] = [0.02, -0.01, 0.03, 0.00, -0.02, 0.01, 0.015, -0.005]
        let y: [Double] = [0.018, -0.004, 0.021, 0.006, -0.011, 0.004, 0.019, 0.002]
        guard let loose = P.effectiveTrials(returnStreams: [x, y], varianceTarget: 0.50),
              let tight = P.effectiveTrials(returnStreams: [x, y], varianceTarget: 0.99) else {
            Issue.record("both targets should compute"); return
        }
        #expect(tight >= loose)
    }
}
