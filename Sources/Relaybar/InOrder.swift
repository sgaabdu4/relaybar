func inOrder<T>(
    _ items: [T], reason: String, isolation: isolated (any Actor)? = #isolation,
    _ step: (T) async -> Void
) async {
    for item in items { await step(item) }
}
