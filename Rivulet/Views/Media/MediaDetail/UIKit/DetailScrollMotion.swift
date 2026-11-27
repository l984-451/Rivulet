// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

struct DetailScrollMotion {
    private(set) var position: Double
    var target: Double
    private(set) var velocity: Double = 0
    private var lastTime: CFTimeInterval

    init(position: Double, target: Double, time: CFTimeInterval) {
        self.position = position
        self.target = target
        lastTime = time
    }

    mutating func retarget(to target: Double, shiftingPositionBy delta: Double) {
        position += delta
        self.target = target
    }

    mutating func advance(at time: CFTimeInterval) -> Bool {
        guard time.isFinite, time > lastTime else { return false }
        let milliseconds = ((time - lastTime) * 1000).rounded(.towardZero)
        lastTime = time
        guard milliseconds >= 1 else { return false }
        let remaining = target - position
        guard abs(remaining) >= 0.5 else {
            position = target
            velocity = 0
            return true
        }
        let desiredVelocity = remaining * (1 - pow(0.9934, milliseconds))
        var acceleration = desiredVelocity - velocity
        // UIKit limits acceleration toward the destination, while leaving braking unrestricted.
        if acceleration.sign == remaining.sign {
            acceleration = min(10, max(-10, acceleration))
        }
        velocity += acceleration
        position += velocity
        return false
    }
}
