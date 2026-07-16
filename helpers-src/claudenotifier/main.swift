// ClaudeNotify — minimal modern notifier (UNUserNotificationCenter).
// Posts a banner that carries this app's own icon (the Claude logo).
// Interface kept compatible with terminal-notifier: -title X -message Y
// Exit 0 = notification handed to Notification Center; 1 = refused/error.
import Foundation
import UserNotifications

var title = "Claude"
var message = ""
let args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "-help", "--help":
        print("usage: ClaudeNotify -title <title> -message <message>")
        exit(0)
    case "-title" where i + 1 < args.count:
        title = args[i + 1]; i += 2
    case "-message" where i + 1 < args.count:
        message = args[i + 1]; i += 2
    default:
        i += 1
    }
}

let center = UNUserNotificationCenter.current()
let sem = DispatchSemaphore(value: 0)
var delivered = false

center.requestAuthorization(options: [.alert, .sound]) { granted, err in
    if let err = err {
        FileHandle.standardError.write("auth error: \(err)\n".data(using: .utf8)!)
        sem.signal(); return
    }
    if !granted {
        FileHandle.standardError.write("notifications not allowed for ClaudeNotify\n".data(using: .utf8)!)
        sem.signal(); return
    }
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = message
    let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
    center.add(req) { addErr in
        if let addErr = addErr {
            FileHandle.standardError.write("post error: \(addErr)\n".data(using: .utf8)!)
        } else {
            delivered = true
        }
        sem.signal()
    }
}

// generous timeout: the very first run blocks on the user's Allow/Deny choice
_ = sem.wait(timeout: .now() + 60)
exit(delivered ? 0 : 1)
