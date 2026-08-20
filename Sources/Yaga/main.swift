import AppKit

if CommandLine.arguments.contains("--self-test") {
    let done = DispatchSemaphore(value: 0)
    var passed = false
    Task {
        passed = await SelfTest.run()
        done.signal()
    }
    done.wait()
    exit(passed ? 0 : 1)
}

import AppKit

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.delegate = AppController.shared
    application.run()
}
