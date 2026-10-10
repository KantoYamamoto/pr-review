import Foundation
import Darwin

actor BuildLog {
    private let handle: FileHandle
    private var failure: (any Error)?
    init(url: URL) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ReviewError("ビルドログを安全に作成できませんでした。") }
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    func append(_ text: String) {
        do { try handle.write(contentsOf: Data(text.utf8)) }
        catch { failure = error }
    }
    func close() throws {
        try handle.close()
        if let failure { throw failure }
    }
}
