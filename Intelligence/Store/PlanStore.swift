import Foundation

/// Plans and their steps, stored so a job survives the app being suspended.
///
/// Every step writes its state as it goes, which is what lets a plan be resumed with "Continue?"
/// instead of started again — and what lets the user see, afterwards, exactly what was done.
extension IntelligenceStore {
    @discardableResult
    public func save(_ plan: Plan) throws -> Plan {
        var plan = plan
        plan.updatedAt = Date()
        try db.transaction {
            // The plan is also an entity, so it can be referred to, linked to a project and shown.
            try db.run(
                """
                INSERT INTO entities (id, kind, title, title_folded, status, project_id, importance,
                    attributes, created_at, updated_at)
                VALUES (?1, 'plan', ?2, ?3, ?4, ?5, 0.7, '{}', ?6, ?7)
                ON CONFLICT(id) DO UPDATE SET title = ?2, title_folded = ?3, status = ?4,
                    project_id = ?5, updated_at = ?7;
                """,
                [
                    .text(plan.id.uuidString), .text(plan.title), .text(plan.title.intelligenceFolded),
                    .text(plan.state.rawValue), .init(plan.subjectID?.uuidString),
                    .init(plan.createdAt), .init(plan.updatedAt),
                ]
            )
            try db.run(
                """
                INSERT INTO plans (id, request, title, subject_id, state, blocker, scope, step_budget,
                    summary, created_at, updated_at, started_at, finished_at)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
                ON CONFLICT(id) DO UPDATE SET request = ?2, title = ?3, subject_id = ?4, state = ?5,
                    blocker = ?6, scope = ?7, step_budget = ?8, summary = ?9, updated_at = ?11,
                    started_at = ?12, finished_at = ?13;
                """,
                [
                    .text(plan.id.uuidString), .text(plan.request), .text(plan.title),
                    .init(plan.subjectID?.uuidString), .text(plan.state.rawValue),
                    .init(plan.blocker?.rawValue), .text(Self.encodeJSON(plan.scope)),
                    .init(plan.stepBudget), .init(plan.summary), .init(plan.createdAt),
                    .init(plan.updatedAt), .init(plan.startedAt), .init(plan.finishedAt),
                ]
            )
            // Steps are rewritten wholesale: replanning changes the list, and a plan is small.
            try db.run("DELETE FROM plan_steps WHERE plan_id = ?1;", [.text(plan.id.uuidString)])
            for step in plan.steps { try insert(step) }
        }
        return plan
    }

    private func insert(_ step: PlanStep) throws {
        try db.run(
            """
            INSERT INTO plan_steps (id, plan_id, ordinal, capability, summary, arguments, depends_on,
                requires_network, risk, state, blocker, observation, started_at, finished_at, attempts)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15);
            """,
            [
                .text(step.id.uuidString), .text(step.planID.uuidString), .init(step.ordinal),
                .text(step.capability), .text(step.summary), .text(Self.encodeJSON(step.arguments)),
                .text(Self.encodeJSON(step.dependsOn.map(\.uuidString))), .init(step.requiresNetwork),
                .init(step.risk), .text(step.state.rawValue), .init(step.blocker?.rawValue),
                .init(step.observation), .init(step.startedAt), .init(step.finishedAt), .init(step.attempts),
            ]
        )
    }

    /// Updates one step in place. The hot path while a plan runs, so it touches one row.
    public func update(_ step: PlanStep) throws {
        try db.run(
            """
            UPDATE plan_steps SET arguments = ?2, state = ?3, blocker = ?4, observation = ?5,
                started_at = ?6, finished_at = ?7, attempts = ?8
            WHERE id = ?1;
            """,
            [
                .text(step.id.uuidString), .text(Self.encodeJSON(step.arguments)),
                .text(step.state.rawValue), .init(step.blocker?.rawValue), .init(step.observation),
                .init(step.startedAt), .init(step.finishedAt), .init(step.attempts),
            ]
        )
        try db.run(
            "UPDATE plans SET updated_at = ?2 WHERE id = ?1;",
            [.text(step.planID.uuidString), .init(Date())]
        )
    }

    public func plan(_ id: UUID) throws -> Plan? {
        guard let row = try db.query(
            "SELECT \(IntelligenceSchema.planColumns) FROM plans WHERE id = ?1;", [.text(id.uuidString)]
        ).first else { return nil }
        var plan = Self.plan(from: row)
        plan.steps = try steps(of: id)
        return plan
    }

    public func steps(of planID: UUID) throws -> [PlanStep] {
        try db.query(
            "SELECT \(IntelligenceSchema.planStepColumns) FROM plan_steps WHERE plan_id = ?1 ORDER BY ordinal;",
            [.text(planID.uuidString)]
        ).map(Self.step(from:))
    }

    /// Plans in a set of states, newest first. Used for "what are you doing?" and for resuming
    /// after a relaunch.
    public func plans(states: [PlanState] = [], limit: Int = 20) throws -> [Plan] {
        var bindings: [SQLValue] = []
        var filter = ""
        if !states.isEmpty {
            let placeholders = states.map { state -> String in
                bindings.append(.text(state.rawValue))
                return "?\(bindings.count)"
            }
            filter = "WHERE state IN (\(placeholders.joined(separator: ", ")))"
        }
        let rows = try db.query(
            """
            SELECT \(IntelligenceSchema.planColumns) FROM plans \(filter)
            ORDER BY updated_at DESC LIMIT \(max(1, limit));
            """,
            bindings
        )
        return try rows.map(Self.plan(from:)).map { plan in
            var plan = plan
            plan.steps = try steps(of: plan.id)
            return plan
        }
    }

    /// Jobs that were running when the app went away, so they can be offered back to the user.
    public func resumablePlans() throws -> [Plan] {
        try plans(states: [.running, .approved, .blocked])
    }

    public func deletePlan(_ id: UUID) throws {
        try db.transaction {
            try db.run("DELETE FROM plan_steps WHERE plan_id = ?1;", [.text(id.uuidString)])
            try db.run("DELETE FROM plans WHERE id = ?1;", [.text(id.uuidString)])
            try db.run("DELETE FROM entities WHERE id = ?1;", [.text(id.uuidString)])
        }
    }

    // MARK: Mapping

    static func plan(from row: SQLRow) -> Plan {
        Plan(
            id: UUID(uuidString: row.string(0) ?? "") ?? UUID(),
            request: row.string(1) ?? "",
            title: row.string(2) ?? "",
            subjectID: row.string(3).flatMap(UUID.init(uuidString:)),
            state: PlanState(rawValue: row.string(4) ?? "") ?? .proposed,
            blocker: row.string(5).flatMap(PlanBlocker.init(rawValue:)),
            scope: decodeJSON([String].self, row.string(6)) ?? [],
            steps: [],
            stepBudget: Int(row.int(7) ?? 8),
            summary: row.string(8),
            createdAt: row.date(9) ?? Date(),
            updatedAt: row.date(10) ?? Date(),
            startedAt: row.date(11),
            finishedAt: row.date(12)
        )
    }

    static func step(from row: SQLRow) -> PlanStep {
        PlanStep(
            id: UUID(uuidString: row.string(0) ?? "") ?? UUID(),
            planID: UUID(uuidString: row.string(1) ?? "") ?? UUID(),
            ordinal: Int(row.int(2) ?? 0),
            capability: row.string(3) ?? "",
            summary: row.string(4) ?? "",
            arguments: decodeJSON([String: String].self, row.string(5)) ?? [:],
            dependsOn: (decodeJSON([String].self, row.string(6)) ?? []).compactMap(UUID.init(uuidString:)),
            requiresNetwork: row.bool(7),
            risk: Int(row.int(8) ?? 0),
            state: PlanState(rawValue: row.string(9) ?? "") ?? .proposed,
            blocker: row.string(10).flatMap(PlanBlocker.init(rawValue:)),
            observation: row.string(11),
            startedAt: row.date(12),
            finishedAt: row.date(13),
            attempts: Int(row.int(14) ?? 0)
        )
    }

    static func encodeJSON(_ value: some Encodable) -> String {
        (try? JSONEncoder().encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    static func decodeJSON<T: Decodable>(_ type: T.Type, _ json: String?) -> T? {
        json?.data(using: .utf8).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}
