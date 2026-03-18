import Foundation

// Helper extensions borrowed from Ghostty's macOS app for C interop.

extension Optional where Wrapped == String {
    func withCString<T>(_ body: (UnsafePointer<Int8>?) throws -> T) rethrows -> T {
        if let string = self {
            return try string.withCString(body)
        } else {
            return try body(nil)
        }
    }
}

extension Array where Element == String {
    func withCStrings<T>(_ body: ([UnsafePointer<Int8>?]) throws -> T) rethrows -> T {
        if isEmpty {
            return try body([])
        }

        func helper(index: Int, accumulated: [UnsafePointer<Int8>?], body: ([UnsafePointer<Int8>?]) throws -> T) rethrows -> T {
            if index == count {
                return try body(accumulated)
            }

            return try self[index].withCString { cStr in
                var newAccumulated = accumulated
                newAccumulated.append(cStr)
                return try helper(index: index + 1, accumulated: newAccumulated, body: body)
            }
        }

        return try helper(index: 0, accumulated: [], body: body)
    }
}
