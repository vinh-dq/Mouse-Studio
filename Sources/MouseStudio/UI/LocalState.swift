import SwiftUI

/// Stand-in for `@State`. With only the Command Line Tools installed (no Xcode), the SDK's `@State` macro
/// plugin is missing and the compiler rejects `@State`; this wraps the underlying `State` value instead.
/// Behaves identically, and builds with or without Xcode.
@propertyWrapper
struct LocalState<Value>: DynamicProperty {
    private var storage: SwiftUI.State<Value>

    init(wrappedValue: Value) {
        storage = SwiftUI.State<Value>(initialValue: wrappedValue)
    }

    var wrappedValue: Value {
        get { storage.wrappedValue }
        nonmutating set { storage.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { storage.projectedValue }
}
