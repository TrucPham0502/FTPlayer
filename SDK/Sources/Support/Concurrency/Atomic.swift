import os.lock

@propertyWrapper
final class Atomic<T> {
    private var lock = os_unfair_lock()
    private var value: T
    init(wrappedValue: T) { self.value = wrappedValue }
    var wrappedValue: T {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return value }
        set { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; value = newValue }
    }
}
