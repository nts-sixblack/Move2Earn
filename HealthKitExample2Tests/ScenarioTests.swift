import Testing
@testable import HealthKitExample2

/// Every honest and cheating scenario must produce the expected server decision.
struct ScenarioTests {
    @Test(arguments: Scenario.allCases)
    func scenario(_ scenario: Scenario) {
        let result = ScenarioRunner().run(scenario)
        let flags = result.receipt.allFlags.map { "\($0.code.rawValue)(\($0.severity.rawValue))" }
        #expect(result.passed, "\(scenario.rawValue): status=\(result.receipt.status) coins=\(result.receipt.coins) note=\(result.note) flags=\(Set(flags).sorted())")
    }

    @Test func recoveredEarnsLessThanLive() {
        let runner = ScenarioRunner()
        let live = runner.run(.legitWalk).receipt.coins
        let recovered = runner.run(.killedAndRecovered).receipt.coins
        #expect(recovered < live)
        #expect(recovered > 0)
    }
}
