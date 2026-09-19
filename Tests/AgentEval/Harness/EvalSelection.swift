import Foundation

public enum EvalSelection {
    /// Deterministic stratified subset: round-robin across categories in dataset order, so a small
    /// run still covers every category.
    public static func stratified(_ cases: [EvalCase], limit: Int) -> [EvalCase] {
        var byCategory: [String: [EvalCase]] = [:]
        var order: [String] = []
        for evalCase in cases {
            if byCategory[evalCase.category] == nil { order.append(evalCase.category) }
            byCategory[evalCase.category, default: []].append(evalCase)
        }
        var result: [EvalCase] = []
        var index = 0
        while result.count < limit {
            var added = false
            for category in order where index < byCategory[category]!.count && result.count < limit {
                result.append(byCategory[category]![index])
                added = true
            }
            if !added { break }
            index += 1
        }
        return result
    }
}
