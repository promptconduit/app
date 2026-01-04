import Foundation

/// Layout configuration for multi-terminal grid displays
enum GridLayout: String, Codable, CaseIterable {
    case auto           // Auto-calculate based on terminal count
    case horizontal     // 1xN (single row)
    case vertical       // Nx1 (single column)
    case grid2x2        // 2x2 grid
    case grid2x3        // 2x3 grid
    case grid2x4        // 2x4 grid

    var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .horizontal: return "Horizontal"
        case .vertical: return "Vertical"
        case .grid2x2: return "2×2 Grid"
        case .grid2x3: return "2×3 Grid"
        case .grid2x4: return "2×4 Grid"
        }
    }

    /// Calculate grid dimensions based on terminal count
    /// - Parameter count: Number of terminals (1-8)
    /// - Returns: Tuple of (rows, columns)
    func dimensions(for count: Int) -> (rows: Int, cols: Int) {
        switch self {
        case .auto:
            return Self.autoDimensions(for: count)
        case .horizontal:
            return (1, min(count, 8))
        case .vertical:
            return (min(count, 8), 1)
        case .grid2x2:
            return (2, 2)
        case .grid2x3:
            return (2, 3)
        case .grid2x4:
            return (2, 4)
        }
    }

    /// Auto-calculate optimal grid dimensions
    /// Layout progression: 1=1x1, 2=1x2, 3=1x3, 4=2x2, 5-6=2x3, 7-8=2x4
    static func autoDimensions(for count: Int) -> (rows: Int, cols: Int) {
        switch count {
        case 0, 1:
            return (1, 1)
        case 2:
            return (1, 2)
        case 3:
            return (1, 3)
        case 4:
            return (2, 2)
        case 5, 6:
            return (2, 3)
        case 7, 8:
            return (2, 4)
        default:
            return (2, 4)  // Max supported
        }
    }

    /// Calculate recommended window size for the grid
    /// - Parameter count: Number of terminals
    /// - Returns: Recommended window size
    func windowSize(for count: Int) -> (width: CGFloat, height: CGFloat) {
        let dims = dimensions(for: count)
        let cellWidth: CGFloat = 450
        let cellHeight: CGFloat = 350
        let headerHeight: CGFloat = 50
        let spacing: CGFloat = 2

        let width = cellWidth * CGFloat(dims.cols) + spacing * CGFloat(dims.cols - 1)
        let height = cellHeight * CGFloat(dims.rows) + spacing * CGFloat(dims.rows - 1) + headerHeight

        return (width, height)
    }

    /// Minimum window size for the grid
    func minimumWindowSize(for count: Int) -> (width: CGFloat, height: CGFloat) {
        let dims = dimensions(for: count)
        let minCellWidth: CGFloat = 350
        let minCellHeight: CGFloat = 250
        let headerHeight: CGFloat = 50

        let width = minCellWidth * CGFloat(dims.cols)
        let height = minCellHeight * CGFloat(dims.rows) + headerHeight

        return (width, height)
    }
}
