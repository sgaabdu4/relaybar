import CoreServices
import Foundation

final class Watcher {
    private var stream: FSEventStreamRef?
    private let handler: ([String]) -> Void

    init(paths: [String], handler: @escaping ([String]) -> Void) {
        self.handler = handler
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<Watcher>.fromOpaque(info).takeUnretainedValue()
            watcher.handler(unsafeBitCast(paths, to: NSArray.self) as? [String] ?? [])
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
        guard
            let stream = FSEventStreamCreate(
                nil, callback, &context, paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 5, flags)
        else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
