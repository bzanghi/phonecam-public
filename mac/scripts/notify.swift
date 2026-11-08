import Foundation
// usage: notify <name> [object-string]
DistributedNotificationCenter.default().postNotificationName(Notification.Name(CommandLine.arguments[1]),
    object: CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : nil, userInfo: nil, deliverImmediately: true)
