import CoreGraphics

public enum DesktopIconLayout {
    public static func pill(in tile: CGRect, textWidth: CGFloat) -> CGRect {
        let unit = tile.width
        let height = unit * 0.23
        return CGRect(
            x: tile.minX + unit * 0.09, y: tile.minY + unit * 0.09, width: max(height, textWidth + unit * 0.1), height: height)
    }

    public static func logo(in tile: CGRect, tagged: Bool) -> CGRect {
        let unit = tile.width
        guard tagged else { return tile.insetBy(dx: unit * 0.21, dy: unit * 0.21) }
        return CGRect(x: tile.minX + unit * 0.25, y: tile.minY + unit * 0.36, width: unit * 0.5, height: unit * 0.5)
    }
}
