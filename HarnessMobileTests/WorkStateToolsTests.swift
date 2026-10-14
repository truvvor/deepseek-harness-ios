import XCTest
#if canImport(HarnessMobile)
@testable import HarnessMobile
#else
@testable import HarnessMobileCore
#endif

final class WorkStateToolsTests: XCTestCase {
    func testGoalPlanAndTodosUpdateOneLocalCoordinator() async throws {
        let coordinator = WorkStateCoordinator()
        let goal = WorkStateSetGoalTool(coordinator: coordinator)
        let plan = WorkStateReplacePlanTool(coordinator: coordinator)
        let todos = WorkStateReplaceTodosTool(coordinator: coordinator)

        _ = try await goal.execute(arguments: [
            "title": .string("Organize materials"),
            "status": .string("active")
        ])
        _ = try await plan.execute(arguments: [
            "steps": .array([
                .object(["title": .string("Read"), "status": .string("completed")]),
                .object(["title": .string("Summarize"), "status": .string("active")])
            ])
        ])
        _ = try await todos.execute(arguments: [
            "items": .array([
                .object(["title": .string("Verify sources"), "status": .string("pending")])
            ])
        ])

        let state = await coordinator.snapshot()
        XCTAssertEqual(state.goal?.title, "Organize materials")
        XCTAssertEqual(state.goal?.status, .active)
        XCTAssertEqual(state.plan.map(\.status), [.completed, .active])
        XCTAssertEqual(state.todos.map(\.title), ["Verify sources"])
    }

    /// Mirrors upstream `dsh-goal-round-driver`: goal rounds are opt-in, count
    /// against a cap, and a spent cap records a blocker instead of stopping
    /// silently. Editing a goal must not reset that accounting.
    func testGoalRoundsCountAgainstCapAndBlockWhenSpent() async throws {
        let coordinator = WorkStateCoordinator()
        _ = try await coordinator.applyGoalAction(.create(title: "Organize materials"))
        // Continuation is off by default: no auto round.
        let beforeEnabling = await coordinator.startGoalRound()
        XCTAssertFalse(beforeEnabling)

        _ = try await coordinator.setGoalContinuation(enabled: true, maximumRounds: 2)
        let first = await coordinator.startGoalRound()
        let second = await coordinator.startGoalRound()
        let third = await coordinator.startGoalRound()
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        // Cap spent.
        XCTAssertFalse(third)
        let spent = await coordinator.snapshot().goal
        XCTAssertEqual(spent?.usedRounds, 2)
        XCTAssertNotNil(spent?.blocker)

        // Editing the goal keeps the accounting.
        _ = try await coordinator.applyGoalAction(.edit(title: "Organize materials (revised)"))
        let edited = await coordinator.snapshot().goal
        XCTAssertEqual(edited?.usedRounds, 2)
        XCTAssertTrue(edited?.isContinuationEnabled == true)
    }

    /// Upstream exposes `get_goal` for the same reason: a model resuming a
    /// long task reads durable work state instead of guessing from history.
    func testWorkStateGetReturnsCurrentGoalPlanAndTodos() async throws {
        let coordinator = WorkStateCoordinator()
        let get = WorkStateGetTool(coordinator: coordinator)
        let setGoal = WorkStateSetGoalTool(coordinator: coordinator)

        // `goal` is optional, so an empty state encodes without the key.
        let empty = try JSONDecoder().decode(
            ConversationWorkState.self,
            from: Data(try await get.execute(arguments: [:]).utf8)
        )
        XCTAssertNil(empty.goal)

        _ = try await setGoal.execute(arguments: [
            "title": .string("Organize materials"),
            "status": .string("active")
        ])
        let populated = try JSONDecoder().decode(
            ConversationWorkState.self,
            from: Data(try await get.execute(arguments: [:]).utf8)
        )
        XCTAssertEqual(populated.goal?.title, "Organize materials")
        XCTAssertEqual(populated.goal?.status, .active)
        XCTAssertEqual(get.definition.name, "work_state_get")
        XCTAssertFalse(get.risk.requiresApproval)
    }

    func testWorkStateToolsRejectUnknownKeysAndInvalidStatus() async {
        let coordinator = WorkStateCoordinator()
        let goal = WorkStateSetGoalTool(coordinator: coordinator)

        do {
            _ = try await goal.execute(arguments: [
                "title": .string("Goal"),
                "status": .string("invented"),
                "remote": .bool(true)
            ])
            XCTFail("Invalid work-state input should be rejected")
        } catch {
            XCTAssertTrue(error is LocalToolError)
        }

        let state = await coordinator.snapshot()
        XCTAssertNil(state.goal)
    }

    func testTodoStatusErrorNamesFieldAndAllowedValues() async {
        let tool = WorkStateReplaceTodosTool(coordinator: WorkStateCoordinator())

        do {
            _ = try await tool.execute(arguments: [
                "items": .array([
                    .object([
                        "title": .string("Test"),
                        "status": .string("in_progress")
                    ])
                ])
            ])
            XCTFail("Invalid status should be rejected")
        } catch {
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("status"))
            XCTAssertTrue(message.contains("in_progress"))
            XCTAssertTrue(message.contains("pending"))
            XCTAssertTrue(message.contains("active"))
            XCTAssertFalse(message.contains("not a valid JSON object"))
        }
    }

    func testGoalLifecyclePreservesIdentityAcrossEditAndStatusTransitions() async throws {
        let original = ConversationGoal(title: "Finish the mobile port", status: .active)
        let coordinator = WorkStateCoordinator(
            state: ConversationWorkState(goal: original)
        )

        var state = try await coordinator.applyGoalAction(
            .edit(title: "  Finish the mobile Harness port  ")
        )
        XCTAssertEqual(state.goal?.id, original.id)
        XCTAssertEqual(state.goal?.title, "Finish the mobile Harness port")

        state = try await coordinator.applyGoalAction(.pause)
        XCTAssertEqual(state.goal?.status, .paused)
        state = try await coordinator.applyGoalAction(.resume)
        XCTAssertEqual(state.goal?.status, .active)
        state = try await coordinator.applyGoalAction(.block)
        XCTAssertEqual(state.goal?.status, .blocked)
        state = try await coordinator.applyGoalAction(.resume)
        XCTAssertEqual(state.goal?.status, .active)
        state = try await coordinator.applyGoalAction(.complete)
        XCTAssertEqual(state.goal?.status, .completed)
        XCTAssertEqual(state.goal?.id, original.id)

        state = try await coordinator.applyGoalAction(.clear)
        XCTAssertNil(state.goal)
    }

    func testGoalLifecycleRejectsInvalidTransitionsWithoutChangingState() async throws {
        let original = ConversationGoal(title: "Keep state", status: .active)
        let coordinator = WorkStateCoordinator(
            state: ConversationWorkState(goal: original)
        )

        do {
            _ = try await coordinator.applyGoalAction(.resume)
            XCTFail("An already active goal cannot be resumed")
        } catch let error as ConversationGoalLifecycleError {
            XCTAssertEqual(
                error,
                .invalidTransition(from: .active, to: .active)
            )
        }

        do {
            _ = try await coordinator.applyGoalAction(.edit(title: "   "))
            XCTFail("An empty goal objective must be rejected")
        } catch let error as ConversationGoalLifecycleError {
            XCTAssertEqual(error, .emptyTitle)
        }

        let state = await coordinator.snapshot()
        XCTAssertEqual(state.goal, original)
    }

    func testModelGoalUpdatesRetainIdentityUntilACompletedGoalIsReplaced() async throws {
        let coordinator = WorkStateCoordinator()
        let tool = WorkStateSetGoalTool(coordinator: coordinator)

        _ = try await tool.execute(arguments: [
            "title": .string("First version goal"),
            "status": .string("active")
        ])
        let first = (await coordinator.snapshot()).goal

        _ = try await tool.execute(arguments: [
            "title": .string("Revised goal"),
            "status": .string("paused")
        ])
        let revised = (await coordinator.snapshot()).goal
        XCTAssertEqual(revised?.id, first?.id)

        _ = try await tool.execute(arguments: [
            "title": .string("Revised goal"),
            "status": .string("completed")
        ])
        _ = try await tool.execute(arguments: [
            "title": .string("Next goal"),
            "status": .string("active")
        ])
        let replacement = (await coordinator.snapshot()).goal
        XCTAssertNotEqual(replacement?.id, first?.id)
    }

    /// The goal-round continuation prompt mirrors upstream
    /// `goal-round-driver/src/prompt.ts` so a transcript explains the turn.
    func testGoalRoundPromptCarriesObjectiveAndRoundBudget() {
        let prompt = WorkStateToolSupport.goalRoundPrompt(
            objective: "Organize materials",
            round: 2,
            maximum: 8
        )
        XCTAssertTrue(prompt.contains("<goal_round>"))
        XCTAssertTrue(prompt.contains("Objective: Organize materials"))
        XCTAssertTrue(prompt.contains("Round: 2/8"))
        XCTAssertTrue(prompt.contains("</goal_round>"))
    }
}
