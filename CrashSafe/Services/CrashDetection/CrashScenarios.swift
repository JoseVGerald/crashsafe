import Foundation

/// Repeatable pseudo-random numbers (SplitMix64), so a stress-test run can be reproduced exactly.
nonisolated struct SeededGenerator: RandomNumberGenerator, Sendable {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func uniform(_ range: ClosedRange<Double>) -> Double { Double.random(in: range, using: &self) }

    /// Standard normal (Box–Muller).
    mutating func gaussian() -> Double {
        let u = max(Double.random(in: 0..<1, using: &self), 1e-12), v = Double.random(in: 0..<1, using: &self)
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }

    mutating func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &self) < p }
}

/// How the phone sits in the car: the device's x (right), y (top) and z (out of the screen) axes,
/// written in the car's frame (x forward, y left, z up).
nonisolated struct PhoneMount: Sendable, Equatable {
    var name: String
    var x: SensorVector
    var y: SensorVector
    var z: SensorVector

    /// Upright in a dash or vent mount, screen facing the driver.
    static let dash = PhoneMount(name: "dash mount", x: .init(x: 0, y: -1, z: 0), y: .init(x: 0, y: 0, z: 1), z: .init(x: -1, y: 0, z: 0))
    /// Lying flat on the console, top toward the windshield.
    static let console = PhoneMount(name: "flat on console", x: .init(x: 0, y: -1, z: 0), y: .init(x: 1, y: 0, z: 0), z: .init(x: 0, y: 0, z: 1))
    /// In a pants pocket while seated.
    static let pocket = PhoneMount(name: "pocket", x: .init(x: 0, y: 0, z: 1), y: .init(x: 1, y: 0, z: 0), z: .init(x: 0, y: 1, z: 0))
    /// Upright in a cup holder, leaning back.
    static let cupHolder = PhoneMount(name: "cup holder", x: .init(x: 0, y: -1, z: 0),
                                      y: .init(x: -0.342, y: 0, z: 0.940), z: .init(x: -0.940, y: 0, z: -0.342))
    static let standard = [dash, console, pocket, cupHolder]

    /// Any orientation at all.
    static func random(using rng: inout SeededGenerator) -> PhoneMount {
        func unit(_ v: SensorVector) -> SensorVector { v * (1 / max(v.magnitude, 1e-9)) }
        let a = unit(SensorVector(x: rng.gaussian(), y: rng.gaussian(), z: rng.gaussian()))
        var b = SensorVector(x: rng.gaussian(), y: rng.gaussian(), z: rng.gaussian())
        b = unit(b - a * b.dot(a))
        let c = SensorVector(x: a.y * b.z - a.z * b.y, y: a.z * b.x - a.x * b.z, z: a.x * b.y - a.y * b.x)
        return PhoneMount(name: "random", x: a, y: b, z: c)
    }

    /// A car-frame vector in the phone's frame.
    func device(_ v: SensorVector) -> SensorVector { SensorVector(x: v.dot(x), y: v.dot(y), z: v.dot(z)) }
    /// Core Motion's gravity reading for this mount.
    var gravity: SensorVector { device(SensorVector(x: 0, y: 0, z: -1)) }
}

/// One recorded (or generated) event as the phone would sense it: 100 Hz motion and 1 Hz GPS,
/// with the truth attached. Used by the stress test and replayed into the simulator.
nonisolated struct SensorScenario: Sendable {
    nonisolated enum Kind: String, CaseIterable, Sendable {
        // Crashes: the app should start a check-in.
        case frontalCrash, rearEndedWhileStopped, sideImpact, lowSpeedCrash
        // Not crashes: the app should stay quiet.
        case phoneDropMoving, phoneDropParked, phoneFliesOffMountWhileBraking, pothole, speedBump,
             roughRoad, hardBrake, doorSlam, phoneTossedOnSeat, normalDriving

        var isCrash: Bool { [.frontalCrash, .rearEndedWhileStopped, .sideImpact, .lowSpeedCrash].contains(self) }

        var title: String {
            switch self {
            case .frontalCrash: "Frontal crash"
            case .rearEndedWhileStopped: "Rear-ended while stopped"
            case .sideImpact: "Side impact (T-bone)"
            case .lowSpeedCrash: "Low-speed crash (fender bender)"
            case .phoneDropMoving: "Phone dropped while driving"
            case .phoneDropParked: "Phone dropped while parked"
            case .phoneFliesOffMountWhileBraking: "Emergency stop, phone flies off mount"
            case .pothole: "Pothole"
            case .speedBump: "Speed bump"
            case .roughRoad: "Rough road / rail crossing"
            case .hardBrake: "Hard braking"
            case .doorSlam: "Door slam (phone in door pocket)"
            case .phoneTossedOnSeat: "Phone tossed onto seat"
            case .normalDriving: "Normal driving (60 s)"
            }
        }
    }

    var kind: Kind
    var title: String
    var readings: [SensorReading]
    /// When the event happens (impact, landing, bump), on the readings' clock.
    var eventUptime: TimeInterval
    /// The car's real speed change in the crash, m/s.
    var trueDeltaVMPS: Double?
    var mount: String
    var detail: String
}

/// Builds `SensorScenario`s from simple physics. Every number is drawn from a stated range so the
/// stress test covers the variety of real events rather than one hand-picked example.
nonisolated struct ScenarioFactory: Sendable {
    var hz = 100.0
    /// Per-axis accelerometer range, g (Core Motion clips here; older iPhones ±8 g, newer ±16 g).
    var saturationG = 16.0
    var start: TimeInterval = 1_000

    /// What the phone senses at one instant, already in the phone's frame.
    nonisolated struct PhoneState: Sendable {
        var user: SensorVector
        var gravity: SensorVector
        var rotation: SensorVector
    }

    /// The core renderer.
    /// - Parameters:
    ///   - carAccel: the car's acceleration at time t (s from start), car frame, g (pulses, braking, bumps).
    ///   - yawRate: the car's rotation about its vertical axis, rad/s.
    ///   - speed: the car's true speed (m/s) for GPS.
    ///   - loose: when the phone isn't moving with the car (falling, tumbling), its own reading.
    func render(kind: SensorScenario.Kind, duration: Double, eventTime: Double, mount: PhoneMount,
                vibration: Double, gpsLag: Double = 0.7, gpsOutage: ClosedRange<Double>? = nil,
                quiet: ClosedRange<Double>? = nil,
                hasGPS: Bool = true, trueDeltaV: Double? = nil, detail: String,
                rng: inout SeededGenerator,
                carAccel: (Double) -> SensorVector, yawRate: (Double) -> Double = { _ in 0 },
                speed: (Double) -> Double, loose: ((Double) -> PhoneState?)? = nil) -> SensorScenario {
        var readings: [SensorReading] = []
        readings.reserveCapacity(Int(duration * (hz + 1)))
        let count = Int(duration * hz)
        let gravity = mount.gravity
        // Smooth road sway plus white noise.
        let phases = (0..<4).map { _ in rng.uniform(0...(2 * .pi)) }
        let gpsPhase = rng.uniform(0...0.99)
        var nextFix = gpsPhase
        var lat = 45.52
        for k in 0..<count {
            let t = Double(k) / hz
            // Average the continuous signal over the 10 ms sample (how the sensor's own filter behaves),
            // so a 4 ms spike reads as a smaller, wider one — as on a real phone.
            var user = SensorVector.zero, rotation = SensorVector.zero, g = gravity
            var looseCount = 0
            for j in 0..<10 {
                let tj = t - 1 / hz + (Double(j) + 0.5) / (10 * hz)
                if let loose, let state = loose(tj) {
                    user = user + state.user; rotation = rotation + state.rotation; g = state.gravity
                    looseCount += 1
                } else {
                    // Core Motion reports user acceleration opposite to the car's acceleration (its
                    // accelerometer reads −1 g on z lying flat); only magnitudes matter to the evaluator.
                    user = user + mount.device(carAccel(tj) * -1)
                    rotation = rotation + mount.device(SensorVector(x: 0, y: 0, z: yawRate(tj)))
                }
            }
            user = user * 0.1; rotation = rotation * 0.1
            if looseCount == 0 { g = gravity }
            let sway = SensorVector(x: 0.6 * sin(2 * .pi * 1.3 * t + phases[0]), y: 0.4 * sin(2 * .pi * 11 * t + phases[1]),
                                    z: 0.5 * sin(2 * .pi * 15 * t + phases[2]))
            // No road vibration reaches a phone in mid-air.
            let moving = speed(t) > 0.5 && !(quiet?.contains(t) ?? false)
            let level = moving ? vibration : vibration * 0.15
            user = user + mount.device(sway * level) + SensorVector(x: rng.gaussian(), y: rng.gaussian(), z: rng.gaussian()) * (level * 0.5 + 0.002)
            rotation = rotation + SensorVector(x: rng.gaussian(), y: rng.gaussian(), z: rng.gaussian()) * (moving ? 0.02 : 0.004)
            // Clip the raw accelerometer (user + gravity) at the sensor's range.
            let raw = user + g
            let clipped = SensorVector(x: max(-saturationG, min(saturationG, raw.x)), y: max(-saturationG, min(saturationG, raw.y)),
                                       z: max(-saturationG, min(saturationG, raw.z)))
            let uptime = start + t
            readings.append(.motion(MotionSample(uptime: uptime, date: Date(timeIntervalSinceReferenceDate: uptime),
                                                 accelerationG: clipped - g, gravityG: g, rotationRate: rotation)))
            if hasGPS, t >= nextFix {
                nextFix += 1
                lat += speed(t) / 111_320
                if !(gpsOutage?.contains(t) ?? false) {
                    let reported = max(0, speed(max(0, t - gpsLag)) + rng.gaussian() * 0.25)
                    readings.append(.location(LocationSample(uptime: uptime + 0.001, date: Date(timeIntervalSinceReferenceDate: uptime),
                                                             latitude: lat, longitude: -122.68, horizontalAccuracy: rng.uniform(3...12),
                                                             speedMPS: reported, speedAccuracy: rng.uniform(0.3...1.2))))
                }
            }
        }
        return SensorScenario(kind: kind, title: kind.title, readings: readings, eventUptime: start + eventTime,
                              trueDeltaVMPS: trueDeltaV, mount: mount.name, detail: detail)
    }

    /// A half-sine pulse that changes speed by `deltaV` (m/s) over `duration` seconds, in g.
    static func halfSine(_ t: Double, at start: Double, duration: Double, deltaV: Double) -> Double {
        guard t >= start, t <= start + duration else { return 0 }
        return deltaV * .pi / (2 * duration) * sin(.pi * (t - start) / duration) / SensorVector.standardGravity
    }

    /// Speed change of `halfSine` so far.
    static func halfSineSpeed(_ t: Double, at start: Double, duration: Double, deltaV: Double) -> Double {
        guard t > start else { return 0 }
        guard t < start + duration else { return deltaV }
        return deltaV * (1 - cos(.pi * (t - start) / duration)) / 2
    }

    // MARK: Scenarios

    func make(_ kind: SensorScenario.Kind, rng: inout SeededGenerator) -> SensorScenario {
        let mount = rng.chance(0.6) ? PhoneMount.standard[Int.random(in: 0..<4, using: &rng)] : PhoneMount.random(using: &rng)
        let vibration = rng.uniform(0.015...0.05)
        let te = rng.uniform(4...5)
        switch kind {
        case .frontalCrash, .lowSpeedCrash:
            let low = kind == .lowSpeedCrash
            let v0 = low ? rng.uniform(3...8) : rng.uniform(8...30)
            let dv = low ? rng.uniform(1.5...min(4.5, v0)) : rng.uniform(3...min(20, v0 + 4))
            let pulse = low ? rng.uniform(0.12...0.25) : rng.uniform(0.07...0.18)
            let after = max(0, v0 - dv)
            let decel = rng.uniform(0.3...0.7)
            let spin = rng.uniform(0...(low ? 1 : 4))
            let stopAt = te + pulse + after / (decel * SensorVector.standardGravity)
            let outage = rng.chance(0.1) ? (te + 0.2)...(te + 6) : nil
            return render(kind: kind, duration: 12, eventTime: te, mount: mount, vibration: vibration, gpsOutage: outage,
                          trueDeltaV: dv, detail: String(format: "%.0f mph, Δv %.1f mph, %.0f ms pulse%@", v0 * 2.237, dv * 2.237, pulse * 1000,
                                                         outage == nil ? "" : ", GPS lost after impact"),
                          rng: &rng,
                          carAccel: { t in
                              let x = -Self.halfSine(t, at: te, duration: pulse, deltaV: dv)
                              let braking = t > te + pulse && t < stopAt ? -decel : 0
                              return SensorVector(x: x + braking, y: 0, z: 0)
                          },
                          yawRate: { t in t >= te && t <= te + 0.6 ? spin * sin(.pi * (t - te) / 0.6) : 0 },
                          speed: { t in
                              if t < te { return v0 }
                              if t < te + pulse { return max(0, v0 - Self.halfSineSpeed(t, at: te, duration: pulse, deltaV: dv)) }
                              return max(0, after - decel * SensorVector.standardGravity * (t - te - pulse))
                          })
        case .rearEndedWhileStopped:
            let dv = rng.uniform(2...8)
            let pulse = rng.uniform(0.09...0.2)
            let brake = rng.uniform(0.3...0.8)
            let stopAt = te + pulse + dv / (brake * SensorVector.standardGravity)
            return render(kind: kind, duration: 12, eventTime: te, mount: mount, vibration: vibration, trueDeltaV: dv,
                          detail: String(format: "stopped, pushed Δv %.1f mph", dv * 2.237), rng: &rng,
                          carAccel: { t in
                              let x = Self.halfSine(t, at: te, duration: pulse, deltaV: dv)
                              return SensorVector(x: t > te + pulse && t < stopAt ? x - brake : x, y: 0, z: 0)
                          },
                          speed: { t in
                              if t < te { return 0 }
                              if t < te + pulse { return Self.halfSineSpeed(t, at: te, duration: pulse, deltaV: dv) }
                              return max(0, dv - brake * SensorVector.standardGravity * (t - te - pulse))
                          })
        case .sideImpact:
            let v0 = rng.chance(0.5) ? 0 : rng.uniform(3...15)
            let dv = rng.uniform(3...10)
            let pulse = rng.uniform(0.06...0.15)
            let spin = rng.uniform(1...5)
            let side: Double = rng.chance(0.5) ? 1 : -1
            let decel = rng.uniform(0.4...0.8) * SensorVector.standardGravity
            let lateralStop = te + pulse + dv / decel
            return render(kind: kind, duration: 12, eventTime: te, mount: mount, vibration: vibration, trueDeltaV: dv,
                          detail: String(format: "%.0f mph, side Δv %.1f mph", v0 * 2.237, dv * 2.237), rng: &rng,
                          carAccel: { t in
                              let y = side * Self.halfSine(t, at: te, duration: pulse, deltaV: dv)
                              let slide = t > te + pulse && t < lateralStop ? -side * decel / SensorVector.standardGravity : 0
                              let braking = t > te && v0 > 0 && t < te + v0 / decel ? -decel / SensorVector.standardGravity : 0
                              return SensorVector(x: braking, y: y + slide, z: 0)
                          },
                          yawRate: { t in t >= te && t <= te + 1 ? side * spin * sin(.pi * (t - te)) : 0 },
                          speed: { t in
                              if t < te { return v0 }
                              let forward = max(0, v0 - decel * (t - te))
                              let sideways = t < te + pulse ? Self.halfSineSpeed(t, at: te, duration: pulse, deltaV: dv)
                                  : max(0, dv - decel * (t - te - pulse))
                              return (forward * forward + sideways * sideways).squareRoot()
                          })
        case .phoneDropMoving, .phoneDropParked:
            let v = kind == .phoneDropParked ? 0 : rng.uniform(5...30)
            return drop(kind: kind, speed: { _ in v }, carAccel: { _ in .zero }, mount: mount, vibration: vibration, at: te,
                        height: rng.uniform(0.4...1.3), hasGPS: kind == .phoneDropMoving || rng.chance(0.5),
                        extra: String(format: "%.0f mph", v * 2.237), rng: &rng)
        case .phoneFliesOffMountWhileBraking:
            let v0 = rng.uniform(13...30)
            let brake = rng.uniform(0.7...1.0)
            let tb = te - 0.4
            let stopAt = tb + v0 / (brake * SensorVector.standardGravity)
            return drop(kind: kind, speed: { t in t < tb ? v0 : max(0, v0 - brake * SensorVector.standardGravity * (t - tb)) },
                        carAccel: { t in SensorVector(x: t > tb && t < stopAt ? -brake : 0, y: 0, z: 0) },
                        mount: mount, vibration: vibration, at: te, height: rng.uniform(0.3...0.8), hasGPS: true,
                        extra: String(format: "%.0f mph, %.1f g stop", v0 * 2.237, brake), rng: &rng)
        case .pothole, .speedBump, .roughRoad:
            let v = kind == .speedBump ? rng.uniform(3...9) : rng.uniform(8...25)
            let peak = kind == .pothole ? rng.uniform(2...7) : kind == .speedBump ? rng.uniform(1...3) : rng.uniform(1...3)
            let width = kind == .pothole ? rng.uniform(0.015...0.05) : kind == .speedBump ? rng.uniform(0.1...0.2) : rng.uniform(0.02...0.05)
            let wheelbase = 2.7 / max(v, 1)
            var hits = [te]
            if kind == .speedBump || kind == .pothole { hits.append(te + wheelbase) }
            if kind == .roughRoad { hits = (0..<12).map { te + Double($0) * rng.uniform(0.12...0.25) } }
            let finalHits = hits
            return render(kind: kind, duration: 10, eventTime: te, mount: mount, vibration: vibration,
                          detail: String(format: "%.0f mph, %.1f g, %.0f ms", v * 2.237, peak, width * 1000), rng: &rng,
                          carAccel: { t in
                              var z = 0.0
                              for (i, h) in finalHits.enumerated() where t >= h && t <= h + width {
                                  z += (i == 0 ? peak : peak * 0.7) * sin(.pi * (t - h) / width)
                              }
                              // The suspension rebounds for a second.
                              if let first = finalHits.first, t > first { z += 0.25 * peak * exp(-(t - first) * 3) * sin(2 * .pi * 1.5 * (t - first)) * 0.3 }
                              return SensorVector(x: 0, y: 0, z: z)
                          },
                          speed: { _ in v })
        case .hardBrake:
            let v0 = rng.uniform(12...30)
            let brake = rng.uniform(0.6...1.05)
            let stopAt = te + v0 / (brake * SensorVector.standardGravity)
            return render(kind: kind, duration: 12, eventTime: te, mount: mount, vibration: vibration,
                          detail: String(format: "%.0f mph to 0 at %.2f g", v0 * 2.237, brake), rng: &rng,
                          carAccel: { t in SensorVector(x: t > te && t < stopAt ? -brake : 0, y: 0, z: 0) },
                          speed: { t in t < te ? v0 : max(0, v0 - brake * SensorVector.standardGravity * (t - te)) })
        case .doorSlam:
            let peak = rng.uniform(3...9)
            let width = rng.uniform(0.008...0.03)
            return render(kind: kind, duration: 10, eventTime: te, mount: .pocket, vibration: vibration, hasGPS: rng.chance(0.7),
                          detail: String(format: "%.1f g, %.0f ms", peak, width * 1000), rng: &rng,
                          carAccel: { t in
                              guard t >= te, t <= te + 0.3 else { return .zero }
                              let hit = t <= te + width ? peak * sin(.pi * (t - te) / width) : 0
                              let rattle = 0.4 * exp(-(t - te) * 20) * sin(2 * .pi * 25 * (t - te))
                              return SensorVector(x: 0, y: hit + rattle, z: 0)
                          },
                          speed: { _ in 0 })
        case .phoneTossedOnSeat:
            let v = rng.chance(0.5) ? 0 : rng.uniform(5...25)
            return drop(kind: kind, speed: { _ in v }, carAccel: { _ in .zero }, mount: mount, vibration: vibration, at: te,
                        height: rng.uniform(0.05...0.2), hasGPS: true, landingPeak: rng.uniform(1.5...5), landingWidth: rng.uniform(0.03...0.07),
                        extra: String(format: "%.0f mph, soft landing", v * 2.237), rng: &rng)
        case .normalDriving:
            let base = rng.uniform(8...25)
            let events = (0..<8).map { _ in (at: rng.uniform(2...56), dur: rng.uniform(1.5...4), g: rng.uniform(-0.45...0.35), lateral: rng.chance(0.5)) }
            return render(kind: kind, duration: 60, eventTime: 30, mount: mount, vibration: vibration,
                          detail: String(format: "%.0f mph, braking, turns", base * 2.237), rng: &rng,
                          carAccel: { t in
                              var a = SensorVector.zero
                              for e in events where t >= e.at && t <= e.at + e.dur {
                                  let shape = sin(.pi * (t - e.at) / e.dur)
                                  if e.lateral { a = a + SensorVector(x: 0, y: e.g * shape, z: 0) } else { a = a + SensorVector(x: e.g * shape, y: 0, z: 0) }
                              }
                              return a
                          },
                          yawRate: { t in events.filter { $0.lateral && t >= $0.at && t <= $0.at + $0.dur }.reduce(0) { $0 + $1.g * 0.8 } },
                          speed: { t in
                              var v = base
                              for e in events where !e.lateral && t > e.at {
                                  v += e.g * SensorVector.standardGravity * (min(t, e.at + e.dur) - e.at) * 2 / .pi
                              }
                              return max(0, v)
                          })
        }
    }

    /// The phone leaves its spot, falls `height` meters tumbling, hits the floor and lies still.
    private func drop(kind: SensorScenario.Kind, speed: @escaping (Double) -> Double, carAccel: @escaping (Double) -> SensorVector,
                      mount: PhoneMount, vibration: Double, at te: Double, height: Double, hasGPS: Bool,
                      landingPeak: Double? = nil, landingWidth: Double? = nil, extra: String,
                      rng: inout SeededGenerator) -> SensorScenario {
        let fall = (2 * height / SensorVector.standardGravity).squareRoot()
        let start = te - fall
        let peak = landingPeak ?? rng.uniform(5...30)
        let width = landingWidth ?? rng.uniform(0.003...0.015)
        let tumble = SensorVector(x: rng.uniform(-8...8), y: rng.uniform(-8...8), z: rng.uniform(-4...4))
        let landed = rng.chance(0.5) ? PhoneMount.console : PhoneMount(name: "face down", x: .init(x: 0, y: 1, z: 0),
                                                                     y: .init(x: 1, y: 0, z: 0), z: .init(x: 0, y: 0, z: -1))
        let bounce = rng.uniform(0.2...0.4)
        return render(kind: kind, duration: 12, eventTime: te, mount: mount, vibration: vibration, quiet: start...te, hasGPS: hasGPS,
                      detail: String(format: "%.1f m fall, %.0f g landing, %@", height, peak, extra), rng: &rng,
                      carAccel: carAccel, speed: speed,
                      loose: { t in
                          guard t >= start else { return nil }
                          if t < te {
                              // Free fall: the accelerometer reads ~0, so user acceleration cancels gravity.
                              let progress = (t - start) / max(fall, 1e-6)
                              let g = (mount.gravity * (1 - progress) + landed.gravity * progress)
                              let n = g * (1 / max(g.magnitude, 1e-6))
                              return PhoneState(user: n * -1, gravity: n, rotation: tumble)
                          }
                          let up = landed.device(SensorVector(x: 0, y: 0, z: 1))
                          var hit = 0.0
                          if t <= te + width { hit = peak * sin(.pi * (t - te) / width) }
                          let tb = te + 0.12
                          if t >= tb && t <= tb + width { hit += peak * bounce * sin(.pi * (t - tb) / width) }
                          let settle = t < te + 0.4 ? tumble * exp(-(t - te) * 15) : .zero
                          // Resting on the car floor, it again feels the car's own motion.
                          return PhoneState(user: up * hit + landed.device(carAccel(t) * -1), gravity: landed.gravity, rotation: settle)
                      })
    }

    /// A real crash recorded by NHTSA (car frame x forward, y right, z down, g, 100 Hz), placed in a
    /// drive: steady speed before, the measured pulse, then the car coming to rest.
    func vehiclePulse(x: [Double], y: [Double], z: [Double], speedBeforeMPS: Double, speedAfterMPS: Double,
                      deltaVMPS: Double, title: String, mount: PhoneMount, rng: inout SeededGenerator) -> SensorScenario {
        let te = rng.uniform(4...5)
        let n = min(x.count, y.count, z.count)
        let pulseLength = Double(n) / 100
        let decel = 0.5 * SensorVector.standardGravity
        func sample(_ t: Double) -> SensorVector {
            let i = Int((t - te) * 100)
            guard i >= 0, i < n else { return .zero }
            return SensorVector(x: x[i], y: -y[i], z: -z[i]) // SAE (y right, z down) → (y left, z up)
        }
        return render(kind: .frontalCrash, duration: 12, eventTime: te, mount: mount, vibration: rng.uniform(0.015...0.05),
                      trueDeltaV: abs(deltaVMPS), detail: title, rng: &rng,
                      carAccel: { t in
                          let s = sample(t)
                          let stopping = t > te + pulseLength && speedAfterMPS > 0 && t < te + pulseLength + speedAfterMPS / decel
                          return s + SensorVector(x: stopping ? -0.5 : 0, y: 0, z: 0)
                      },
                      speed: { t in
                          if t < te { return speedBeforeMPS }
                          if t < te + pulseLength { return speedBeforeMPS + (speedAfterMPS - speedBeforeMPS) * (t - te) / pulseLength }
                          return max(0, speedAfterMPS - decel * (t - te - pulseLength))
                      })
    }
}

/// Runs a scenario through the same pipeline the app uses and reports what the driver would see.
nonisolated struct ScenarioOutcome: Sendable {
    var assessments: [CrashAssessment]
    /// The strongest decision reached (suspected crash > inconclusive > rejected), nil if nothing was examined.
    var decision: CrashDecision?
    var alerted: Bool { decision == .suspectedCrash }
    var estimatedDeltaVMPS: Double?

    static func evaluate(_ scenario: SensorScenario, configuration: CrashEvaluationConfiguration = .init()) -> ScenarioOutcome {
        var pipeline = CrashPipeline(configuration: configuration)
        var history = SensorHistory()
        var assessments: [CrashAssessment] = []
        for reading in scenario.readings {
            history.append(reading)
            if let a = pipeline.ingest(reading) { assessments.append(a) }
        }
        if let last = scenario.readings.last?.uptime, let a = pipeline.advance(to: last + 10) { assessments.append(a) }
        let rank: [CrashDecision: Int] = [.rejected: 0, .inconclusive: 1, .suspectedCrash: 2]
        let decision = assessments.map(\.decision).max { rank[$0]! < rank[$1]! }
        let alert = assessments.first { $0.decision == .suspectedCrash }
        let estimate = alert.flatMap { ImpactAnalyzer.analyze(history: history, impactUptime: $0.candidate.uptime)?.deltaVMPS }
        return ScenarioOutcome(assessments: assessments, decision: decision, estimatedDeltaVMPS: estimate)
    }
}
