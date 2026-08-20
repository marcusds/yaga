import AppKit

if CommandLine.arguments.contains("--self-test") {
    let done = DispatchSemaphore(value: 0)
    var passed = false
    Task {
        passed = await SelfTest.run()
        done.signal()
    }
    // Pump the run loop rather than blocking outright: parts of the suite are
    // main-actor isolated, and a blocked main thread would deadlock them.
    while done.wait(timeout: .now()) == .timedOut {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
    }
    exit(passed ? 0 : 1)
}

import AppKit

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.delegate = AppController.shared
    application.run()
}
