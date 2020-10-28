/*
 Copyright 2020 TupleStream OÜ
 See the LICENSE file for license information
 SPDX-License-Identifier: Apache-2.0
*/
import Atomics

class Sequence: CustomStringConvertible {

    private let counter: ManagedAtomic<UInt64>

    init(initialValue: UInt64 = 0) {
        self.counter = ManagedAtomic<UInt64>(initialValue)
    }

    var value: UInt64 {
        get {
            return counter.load(ordering: .sequentiallyConsistent)
        }

        set(newValue) {
            counter.store(newValue, ordering: .sequentiallyConsistent)
        }
    }

    func incrementAndGet() -> UInt64 {
        return addAndGet(1)
    }

    func compareAndSet(expected: UInt64, newValue: UInt64) -> Bool {
        return counter.compareExchange(expected: expected, desired: newValue, ordering: .sequentiallyConsistent).exchanged
    }

    func addAndGet(_ increment: UInt64) -> UInt64 {
        var currentValue: UInt64
        var newValue: UInt64 = 0
        var exchanged = false
        while !exchanged {
            currentValue = value
            newValue = currentValue + increment
            exchanged = compareAndSet(expected: currentValue, newValue: newValue)
        }
        return newValue
    }

    var description: String {
        get {
            return "\(counter.load(ordering: .relaxed))"
        }
    }
}
