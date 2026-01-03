import AppKit
import Foundation

/// Service for managing image attachments in terminal sessions
/// Saves images to a temp directory and provides formatted paths for Claude Code
class ImageAttachmentService {
    static let shared = ImageAttachmentService()

    /// Directory for storing temporary image attachments
    private let attachmentsDirectory: URL

    /// Supported image UTTypes for drag & drop and file picker
    static let supportedImageTypes: [String] = [
        "public.png",
        "public.jpeg",
        "public.tiff",
        "public.gif",
        "com.compuserve.gif",
        "public.webp",
        "com.microsoft.bmp",
        "public.heic"
    ]

    private init() {
        // Use Caches directory for temp images
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        attachmentsDirectory = cacheDir.appendingPathComponent("PromptConduit/ImageAttachments", isDirectory: true)

        // Ensure directory exists
        try? FileManager.default.createDirectory(at: attachmentsDirectory, withIntermediateDirectories: true)

        // Clean up old attachments on init
        cleanupOldAttachments()
    }

    // MARK: - Public API

    /// Saves an NSImage to the temp directory
    /// - Parameter image: The image to save
    /// - Returns: URL of the saved file, or nil if save failed
    func saveImage(_ image: NSImage) -> URL? {
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        return saveImageData(pngData, fileExtension: "png")
    }

    /// Saves image data to the temp directory
    /// - Parameters:
    ///   - data: The image data
    ///   - fileExtension: File extension (png, jpg, etc.)
    /// - Returns: URL of the saved file, or nil if save failed
    func saveImageData(_ data: Data, fileExtension: String) -> URL? {
        let filename = generateFilename(extension: fileExtension)
        let fileURL = attachmentsDirectory.appendingPathComponent(filename)

        do {
            try data.write(to: fileURL)
            return fileURL
        } catch {
            print("Failed to save image attachment: \(error)")
            return nil
        }
    }

    /// Copies an existing image file to the temp directory
    /// - Parameter sourceURL: URL of the source image file
    /// - Returns: URL of the copied file, or nil if copy failed
    func copyImageFile(_ sourceURL: URL) -> URL? {
        let fileExtension = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension
        let filename = generateFilename(extension: fileExtension)
        let destURL = attachmentsDirectory.appendingPathComponent(filename)

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            return destURL
        } catch {
            print("Failed to copy image file: \(error)")
            return nil
        }
    }

    /// Formats a file URL as a path suitable for terminal input
    /// Quotes paths containing spaces
    /// - Parameter url: The file URL
    /// - Returns: Formatted path string
    func formatPathForTerminal(_ url: URL) -> String {
        let path = url.path
        // Quote paths with spaces or special characters
        if path.contains(" ") || path.contains("'") || path.contains("\"") {
            // Use single quotes and escape any existing single quotes
            let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
            return "'\(escaped)'"
        }
        return path
    }

    /// Formats multiple file URLs as space-separated paths
    /// - Parameter urls: Array of file URLs
    /// - Returns: Space-separated formatted paths
    func formatPathsForTerminal(_ urls: [URL]) -> String {
        urls.map { formatPathForTerminal($0) }.joined(separator: " ")
    }

    /// Checks if a pasteboard item is an image
    /// - Parameter pasteboard: The pasteboard to check
    /// - Returns: true if pasteboard contains image data
    func pasteboardContainsImage(_ pasteboard: NSPasteboard = .general) -> Bool {
        // Check for image types
        let imageTypes: [NSPasteboard.PasteboardType] = [
            .png,
            .tiff,
            NSPasteboard.PasteboardType("public.jpeg"),
            NSPasteboard.PasteboardType("public.heic")
        ]

        for type in imageTypes {
            if pasteboard.data(forType: type) != nil {
                return true
            }
        }

        // Check for file URLs that are images
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingContentsConformToTypes: Self.supportedImageTypes
        ]) as? [URL], !urls.isEmpty {
            return true
        }

        // Check for NSImage directly
        if pasteboard.readObjects(forClasses: [NSImage.self], options: nil) != nil {
            return true
        }

        return false
    }

    /// Extracts and saves image from pasteboard
    /// - Parameter pasteboard: The pasteboard to extract from
    /// - Returns: URL of saved image, or nil if no image found
    func saveImageFromPasteboard(_ pasteboard: NSPasteboard = .general) -> URL? {
        // Try to get image data directly
        if let pngData = pasteboard.data(forType: .png) {
            return saveImageData(pngData, fileExtension: "png")
        }

        if let tiffData = pasteboard.data(forType: .tiff) {
            // Convert TIFF to PNG
            if let bitmap = NSBitmapImageRep(data: tiffData),
               let pngData = bitmap.representation(using: .png, properties: [:]) {
                return saveImageData(pngData, fileExtension: "png")
            }
        }

        // Try to get file URLs
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingContentsConformToTypes: Self.supportedImageTypes
        ]) as? [URL], let firstURL = urls.first {
            return copyImageFile(firstURL)
        }

        // Try to get NSImage
        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage],
           let image = images.first {
            return saveImage(image)
        }

        return nil
    }

    /// Extracts and saves all images from pasteboard
    /// - Parameter pasteboard: The pasteboard to extract from
    /// - Returns: Array of saved image URLs
    func saveAllImagesFromPasteboard(_ pasteboard: NSPasteboard = .general) -> [URL] {
        var savedURLs: [URL] = []

        // Try file URLs first (for multi-file drag)
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingContentsConformToTypes: Self.supportedImageTypes
        ]) as? [URL] {
            for url in urls {
                if let savedURL = copyImageFile(url) {
                    savedURLs.append(savedURL)
                }
            }
        }

        // If no file URLs, try image data
        if savedURLs.isEmpty {
            if let url = saveImageFromPasteboard(pasteboard) {
                savedURLs.append(url)
            }
        }

        return savedURLs
    }

    // MARK: - Private Helpers

    /// Generates a unique filename with timestamp
    private func generateFilename(extension ext: String) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "+", with: "-")
        let uuid = UUID().uuidString.prefix(8)
        return "image-\(timestamp)-\(uuid).\(ext)"
    }

    /// Removes attachment files older than 24 hours
    private func cleanupOldAttachments() {
        let cutoffDate = Date().addingTimeInterval(-24 * 60 * 60) // 24 hours ago

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: attachmentsDirectory,
            includingPropertiesForKeys: [.creationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        for file in files {
            guard let attributes = try? file.resourceValues(forKeys: [.creationDateKey]),
                  let creationDate = attributes.creationDate,
                  creationDate < cutoffDate else { continue }

            try? FileManager.default.removeItem(at: file)
        }
    }
}
