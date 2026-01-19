import Foundation
import NaturalLanguage

/// Service for generating text embeddings using Apple's NaturalLanguage framework
/// Note: NLEmbedding is NOT thread-safe, so all embedding operations are serialized
class EmbeddingService {

    /// Embedding dimension (NLEmbedding uses 512 dimensions)
    static let embeddingDimension = 512

    private let sentenceEmbedding: NLEmbedding?

    /// Serial queue to ensure thread safety for NLEmbedding operations
    private let embeddingQueue = DispatchQueue(label: "com.promptconduit.embedding")

    init() {
        self.sentenceEmbedding = NLEmbedding.sentenceEmbedding(for: .english)
    }

    /// Check if the embedding service is available
    var isAvailable: Bool {
        sentenceEmbedding != nil
    }

    // MARK: - Embedding Generation

    /// Generate a 512-dimensional embedding vector for the given text
    /// - Parameter text: The text to embed
    /// - Returns: Array of 512 Double values, or nil if embedding fails
    /// - Note: This method is thread-safe and blocks until the embedding is computed
    func embed(_ text: String) -> [Double]? {
        guard let embedding = sentenceEmbedding else {
            return nil
        }

        // NLEmbedding requires lowercase input
        let normalizedText = text.lowercased()

        // Serialize access to NLEmbedding to prevent crashes
        return embeddingQueue.sync {
            embedding.vector(for: normalizedText)
        }
    }

    /// Generate embeddings for multiple texts
    /// - Parameter texts: Array of texts to embed
    /// - Returns: Array of embeddings (nil for texts that couldn't be embedded)
    func embedBatch(_ texts: [String]) -> [[Double]?] {
        return texts.map { embed($0) }
    }

    // MARK: - Similarity Computation

    /// Compute cosine similarity between two embedding vectors
    /// - Parameters:
    ///   - a: First embedding vector
    ///   - b: Second embedding vector
    /// - Returns: Cosine similarity score between -1 and 1 (higher is more similar)
    func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else {
            return 0.0
        }

        var dotProduct: Double = 0.0
        var normA: Double = 0.0
        var normB: Double = 0.0

        for i in 0..<a.count {
            dotProduct += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }

        let denominator = sqrt(normA) * sqrt(normB)
        guard denominator > 0 else {
            return 0.0
        }

        return dotProduct / denominator
    }

    /// Compute cosine distance (1 - similarity) between two embeddings
    /// - Parameters:
    ///   - a: First embedding vector
    ///   - b: Second embedding vector
    /// - Returns: Cosine distance between 0 and 2 (lower is more similar)
    func cosineDistance(_ a: [Double], _ b: [Double]) -> Double {
        return 1.0 - cosineSimilarity(a, b)
    }

    /// Find the most similar embeddings from a collection
    /// - Parameters:
    ///   - query: The query embedding to compare against
    ///   - candidates: Collection of (id, embedding) pairs to search
    ///   - limit: Maximum number of results to return
    ///   - threshold: Minimum similarity score (0-1) to include in results
    /// - Returns: Array of (id, similarity) pairs sorted by similarity descending
    func findSimilar(
        query: [Double],
        in candidates: [(id: Int64, embedding: [Double])],
        limit: Int = 20,
        threshold: Double = 0.0
    ) -> [(id: Int64, similarity: Double)] {
        var results: [(id: Int64, similarity: Double)] = []

        for candidate in candidates {
            let similarity = cosineSimilarity(query, candidate.embedding)
            if similarity >= threshold {
                results.append((id: candidate.id, similarity: similarity))
            }
        }

        // Sort by similarity descending
        results.sort { $0.similarity > $1.similarity }

        // Return top N results
        return Array(results.prefix(limit))
    }

    // MARK: - Text Processing

    /// Preprocess text for better embedding quality
    /// - Parameter text: Raw text input
    /// - Returns: Preprocessed text suitable for embedding
    func preprocessText(_ text: String) -> String {
        var processed = text

        // Remove excessive whitespace
        processed = processed.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // Truncate very long texts (NLEmbedding works best with shorter texts)
        if processed.count > 1000 {
            processed = String(processed.prefix(1000))
        }

        return processed
    }
}

// MARK: - Embedding Data Conversion

extension EmbeddingService {

    /// Convert embedding array to Data for storage
    /// - Parameter embedding: Array of doubles
    /// - Returns: Binary data representation
    static func embeddingToData(_ embedding: [Double]) -> Data {
        return embedding.withUnsafeBufferPointer { pointer in
            Data(buffer: pointer)
        }
    }

    /// Convert Data back to embedding array
    /// - Parameter data: Binary data
    /// - Returns: Array of doubles, or nil if conversion fails
    static func dataToEmbedding(_ data: Data) -> [Double]? {
        guard data.count == embeddingDimension * MemoryLayout<Double>.size else {
            return nil
        }

        return data.withUnsafeBytes { pointer in
            Array(pointer.bindMemory(to: Double.self))
        }
    }
}
