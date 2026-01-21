import Foundation
import CryptoKit

/// Type of message in a transcript
enum TranscriptMessageType: String, Codable {
    case user
    case assistant
    case summary
    case toolResult = "tool_result"
}

/// A parsed message from a Claude Code transcript
struct ParsedTranscriptMessage: Identifiable {
    let id: String          // UUID from the message
    let type: TranscriptMessageType
    let content: String
    let timestamp: Date
    let sessionId: String
    let repoPath: String

    /// Unique identifier for Identifiable conformance
    var uniqueId: String { "\(sessionId)-\(id)" }
}

/// Parses Claude Code JSONL transcript files
class TranscriptParser {

    private let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private let fallbackDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - Public API

    /// Parse a session JSONL file and extract messages
    /// - Parameters:
    ///   - path: Path to the .jsonl session file
    ///   - sessionId: Session ID (filename without extension)
    ///   - repoPath: Repository path this session belongs to
    /// - Returns: Array of parsed messages
    func parseSessionFile(_ path: String, sessionId: String, repoPath: String) -> [ParsedTranscriptMessage] {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }

        var messages: [ParsedTranscriptMessage] = []
        var sequenceNumber = 0

        for line in content.components(separatedBy: .newlines) {
            guard !line.isEmpty,
                  let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] else {
                continue
            }

            if let message = parseMessage(json, sessionId: sessionId, repoPath: repoPath, sequence: &sequenceNumber) {
                messages.append(message)
            }
        }

        return messages
    }

    /// Parse only user messages (prompts) from a session file
    func parseUserMessages(_ path: String, sessionId: String, repoPath: String) -> [ParsedTranscriptMessage] {
        return parseSessionFile(path, sessionId: sessionId, repoPath: repoPath)
            .filter { $0.type == .user }
    }

    /// Parse only assistant messages from a session file
    func parseAssistantMessages(_ path: String, sessionId: String, repoPath: String) -> [ParsedTranscriptMessage] {
        return parseSessionFile(path, sessionId: sessionId, repoPath: repoPath)
            .filter { $0.type == .assistant }
    }

    // MARK: - Private Parsing

    private func parseMessage(_ json: [String: Any], sessionId: String, repoPath: String, sequence: inout Int) -> ParsedTranscriptMessage? {
        guard let typeString = json["type"] as? String else {
            return nil
        }

        // Only parse user and assistant messages for indexing
        guard typeString == "user" || typeString == "assistant" else {
            return nil
        }

        let type: TranscriptMessageType = typeString == "user" ? .user : .assistant

        // Extract UUID
        let uuid = extractUuid(from: json, type: type, sequence: &sequence)

        // Extract content
        guard let content = extractContent(from: json, type: type), !content.isEmpty else {
            return nil
        }

        // Extract timestamp
        let timestamp = extractTimestamp(from: json)

        return ParsedTranscriptMessage(
            id: uuid,
            type: type,
            content: content,
            timestamp: timestamp,
            sessionId: sessionId,
            repoPath: repoPath
        )
    }

    private func extractUuid(from json: [String: Any], type: TranscriptMessageType, sequence: inout Int) -> String {
        if let uuid = json["uuid"] as? String, !uuid.isEmpty {
            return uuid
        }
        sequence += 1
        return "\(type.rawValue)-\(sequence)"
    }

    private func extractContent(from json: [String: Any], type: TranscriptMessageType) -> String? {
        // Try to get content from message.content first
        if let message = json["message"] as? [String: Any] {
            if let content = extractContentFromMessageField(message) {
                return content
            }
        }

        // Fallback: try direct content field
        if let content = json["content"] as? String {
            return content
        }

        return nil
    }

    private func extractContentFromMessageField(_ message: [String: Any]) -> String? {
        guard let content = message["content"] else {
            return nil
        }

        // Content can be a string
        if let stringContent = content as? String {
            return stringContent
        }

        // Content can be an array of content blocks
        if let arrayContent = content as? [[String: Any]] {
            return extractContentFromBlocks(arrayContent)
        }

        return nil
    }

    private func extractContentFromBlocks(_ blocks: [[String: Any]]) -> String? {
        var textParts: [String] = []

        for block in blocks {
            guard let blockType = block["type"] as? String else {
                continue
            }

            switch blockType {
            case "text":
                if let text = block["text"] as? String {
                    textParts.append(text)
                }

            case "tool_result":
                // Skip tool results for indexing - they're often large and noisy
                continue

            case "thinking":
                // Skip thinking blocks - internal reasoning
                continue

            case "tool_use":
                // Skip tool use blocks - they're structured data, not searchable text
                continue

            default:
                // Try to extract text from unknown block types
                if let text = block["text"] as? String {
                    textParts.append(text)
                }
            }
        }

        let combined = textParts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return combined.isEmpty ? nil : combined
    }

    private func extractTimestamp(from json: [String: Any]) -> Date {
        if let timestampString = json["timestamp"] as? String {
            if let date = dateFormatter.date(from: timestampString) {
                return date
            }
            if let date = fallbackDateFormatter.date(from: timestampString) {
                return date
            }
        }
        return Date()
    }

    // MARK: - File Hash

    /// Compute SHA256 hash of a file for change detection
    /// Uses CryptoKit SHA256 for stable hashes across app launches
    func computeFileHash(_ path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }

        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
