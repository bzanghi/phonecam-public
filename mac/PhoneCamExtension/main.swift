import Foundation
import CoreMediaIO

let providerSource = PhoneCamProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
