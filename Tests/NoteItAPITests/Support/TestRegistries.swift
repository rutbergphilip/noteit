@testable import NoteItAPI

/// A registry that keeps bad registrations so `validate()` can report them, for test files without `@testable`.
func nonTrappingRegistry() -> LocalAPIRouteRegistry {
    LocalAPIRouteRegistry(trapsOnProblems: false)
}
