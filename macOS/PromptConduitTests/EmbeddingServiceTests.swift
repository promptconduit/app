import XCTest
@testable import PromptConduit

final class EmbeddingServiceTests: XCTestCase {

    var service: EmbeddingService!

    override func setUp() {
        super.setUp()
        service = EmbeddingService()
    }

    // MARK: - Availability Tests

    func testServiceIsAvailable() {
        // NLEmbedding should be available on macOS
        XCTAssertTrue(service.isAvailable, "EmbeddingService should be available")
    }

    // MARK: - Embedding Generation Tests

    func testEmbeddingReturns512Dimensions() {
        guard service.isAvailable else {
            XCTSkip("Embedding service not available")
            return
        }

        let embedding = service.embed("Hello world")

        XCTAssertNotNil(embedding)
        XCTAssertEqual(embedding?.count, EmbeddingService.embeddingDimension)
        XCTAssertEqual(embedding?.count, 512)
    }

    func testEmbeddingHandlesLongText() {
        guard service.isAvailable else {
            XCTSkip("Embedding service not available")
            return
        }

        let longText = String(repeating: "This is a test sentence. ", count: 100)
        let embedding = service.embed(longText)

        XCTAssertNotNil(embedding)
        XCTAssertEqual(embedding?.count, 512)
    }

    func testEmbeddingPreprocessesText() {
        guard service.isAvailable else {
            XCTSkip("Embedding service not available")
            return
        }

        let preprocessed = service.preprocessText("  Hello    World  \n\n  Test  ")
        XCTAssertEqual(preprocessed, "Hello World Test")
    }

    func testPreprocessTruncatesLongText() {
        let longText = String(repeating: "a", count: 2000)
        let preprocessed = service.preprocessText(longText)

        XCTAssertEqual(preprocessed.count, 1000)
    }

    // MARK: - Cosine Similarity Tests

    func testCosineSimilarityIdenticalVectors() {
        let vector = [1.0, 2.0, 3.0, 4.0]
        let similarity = service.cosineSimilarity(vector, vector)

        XCTAssertEqual(similarity, 1.0, accuracy: 0.0001)
    }

    func testCosineSimilarityOrthogonalVectors() {
        let vectorA = [1.0, 0.0, 0.0]
        let vectorB = [0.0, 1.0, 0.0]
        let similarity = service.cosineSimilarity(vectorA, vectorB)

        XCTAssertEqual(similarity, 0.0, accuracy: 0.0001)
    }

    func testCosineSimilarityOppositeVectors() {
        let vectorA = [1.0, 2.0, 3.0]
        let vectorB = [-1.0, -2.0, -3.0]
        let similarity = service.cosineSimilarity(vectorA, vectorB)

        XCTAssertEqual(similarity, -1.0, accuracy: 0.0001)
    }

    func testCosineSimilarityEmptyVectors() {
        let similarity = service.cosineSimilarity([], [])
        XCTAssertEqual(similarity, 0.0)
    }

    func testCosineSimilarityMismatchedLengths() {
        let vectorA = [1.0, 2.0]
        let vectorB = [1.0, 2.0, 3.0]
        let similarity = service.cosineSimilarity(vectorA, vectorB)

        XCTAssertEqual(similarity, 0.0)
    }

    func testCosineDistanceIsOneMinusSimilarity() {
        let vectorA = [1.0, 2.0, 3.0]
        let vectorB = [4.0, 5.0, 6.0]

        let similarity = service.cosineSimilarity(vectorA, vectorB)
        let distance = service.cosineDistance(vectorA, vectorB)

        XCTAssertEqual(distance, 1.0 - similarity, accuracy: 0.0001)
    }

    // MARK: - Semantic Similarity Tests

    func testSimilarSentencesHaveHighSimilarity() {
        guard service.isAvailable else {
            XCTSkip("Embedding service not available")
            return
        }

        guard let embA = service.embed("How do I fix this bug?"),
              let embB = service.embed("Help me debug this issue") else {
            XCTFail("Failed to generate embeddings")
            return
        }

        let similarity = service.cosineSimilarity(embA, embB)

        // Similar sentences should have positive similarity (NLEmbedding may vary)
        XCTAssertGreaterThan(similarity, 0.3, "Similar sentences should have positive similarity")
    }

    func testDissimilarSentencesHaveLowSimilarity() {
        guard service.isAvailable else {
            XCTSkip("Embedding service not available")
            return
        }

        guard let embA = service.embed("How do I fix this programming bug?"),
              let embB = service.embed("The weather is nice today") else {
            XCTFail("Failed to generate embeddings")
            return
        }

        let similarity = service.cosineSimilarity(embA, embB)

        // Dissimilar sentences should have lower similarity
        XCTAssertLessThan(similarity, 0.6, "Dissimilar sentences should have lower similarity")
    }

    // MARK: - Find Similar Tests

    func testFindSimilarReturnsTopResults() {
        let query = [1.0, 0.0, 0.0]
        let candidates: [(id: Int64, embedding: [Double])] = [
            (id: 1, embedding: [0.9, 0.1, 0.0]),  // Most similar
            (id: 2, embedding: [0.5, 0.5, 0.5]),  // Less similar
            (id: 3, embedding: [0.0, 1.0, 0.0]),  // Orthogonal
            (id: 4, embedding: [0.8, 0.2, 0.0]),  // Second most similar
        ]

        let results = service.findSimilar(query: query, in: candidates, limit: 2)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].id, 1, "Most similar should be first")
        XCTAssertEqual(results[1].id, 4, "Second most similar should be second")
    }

    func testFindSimilarRespectsThreshold() {
        let query = [1.0, 0.0, 0.0]
        let candidates: [(id: Int64, embedding: [Double])] = [
            (id: 1, embedding: [0.9, 0.1, 0.0]),  // High similarity
            (id: 2, embedding: [0.0, 1.0, 0.0]),  // Low similarity (orthogonal)
        ]

        let results = service.findSimilar(query: query, in: candidates, limit: 10, threshold: 0.8)

        // Only the high-similarity result should pass the threshold
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, 1)
    }

    func testFindSimilarRespectsLimit() {
        let query = [1.0, 0.0, 0.0]
        var candidates: [(id: Int64, embedding: [Double])] = []
        for i in 0..<10 {
            candidates.append((id: Int64(i), embedding: [Double(10-i)/10, Double(i)/10, 0.0]))
        }

        let results = service.findSimilar(query: query, in: candidates, limit: 3)

        XCTAssertEqual(results.count, 3)
    }

    // MARK: - Data Conversion Tests

    func testEmbeddingToDataAndBack() {
        // Create a 512-element array to match the expected embedding dimension
        var original = [Double](repeating: 0.0, count: 512)
        for i in 0..<5 {
            original[i] = Double(i + 1)  // [1.0, 2.0, 3.0, 4.0, 5.0, 0, 0, ...]
        }

        let data = EmbeddingService.embeddingToData(original)
        let recovered = EmbeddingService.dataToEmbedding(data)

        XCTAssertNotNil(recovered)
        XCTAssertEqual(recovered?.count, 512)

        // Verify first few values match
        if let recovered = recovered {
            XCTAssertEqual(recovered[0], 1.0, accuracy: 0.0001)
            XCTAssertEqual(recovered[4], 5.0, accuracy: 0.0001)
        }
    }

    func testEmbeddingDataConversionWithCorrectSize() {
        // Create a 512-element array
        var original = [Double](repeating: 0.0, count: 512)
        for i in 0..<512 {
            original[i] = Double(i) * 0.001
        }

        let data = EmbeddingService.embeddingToData(original)
        let recovered = EmbeddingService.dataToEmbedding(data)

        XCTAssertNotNil(recovered)
        XCTAssertEqual(recovered?.count, 512)

        // Check some values
        if let recovered = recovered {
            XCTAssertEqual(recovered[0], original[0], accuracy: 0.0001)
            XCTAssertEqual(recovered[255], original[255], accuracy: 0.0001)
            XCTAssertEqual(recovered[511], original[511], accuracy: 0.0001)
        }
    }

    func testDataToEmbeddingRejectsWrongSize() {
        let wrongSizeData = Data(repeating: 0, count: 100)  // Not 512 * 8 bytes
        let result = EmbeddingService.dataToEmbedding(wrongSizeData)

        XCTAssertNil(result, "Should reject data of wrong size")
    }
}
