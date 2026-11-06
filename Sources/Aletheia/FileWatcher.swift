import Foundation
import CoreServices

/// One OS event stream, no polling or recursive directory enumeration.
@MainActor
final class FileWatcher {
    private var stream: FSEventStreamRef?
    private var paths: [String] = []
    var onChange: ((Set<String>) -> Void)?

    func watch(_ urls: [URL]) throws {
        let candidates = Set(urls.map { $0.resolvingSymlinksInPath().standardizedFileURL.path }).sorted()
        let paths = candidates.filter { path in
            !candidates.contains { $0 != path && path.hasPrefix($0 + "/") }
        }
        guard paths != self.paths else { return }
        stop()
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                          retain: nil, release: nil, copyDescription: nil)
        guard let stream = FSEventStreamCreate(nil, { _, info, count, rawPaths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
            let strings = unsafeBitCast(rawPaths, to: NSArray.self) as! [String]
            let rescanFlags = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUnmount)
            MainActor.assumeIsolated {
                let rescan = (0..<count).contains { flags[$0] & rescanFlags != 0 }
                watcher.onChange?(Set((rescan ? watcher.paths : strings).map { path in
                    let url = URL(fileURLWithPath: path)
                    return url.deletingLastPathComponent().resolvingSymlinksInPath()
                        .appendingPathComponent(url.lastPathComponent).path
                }))
            }
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.25,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)) else {
            throw CocoaError(.fileReadUnknown)
        }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            throw CocoaError(.fileReadUnknown)
        }
        self.stream = stream
        self.paths = paths
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
        paths = []
    }

    isolated deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
