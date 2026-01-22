import UIKit

final class ImageProcessor {
    static let shared = ImageProcessor()

    private init() {}

    // MARK: - Public Methods

    /// Resize an image to fit within the specified maximum dimension while maintaining aspect ratio
    func resize(image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size

        // Check if resizing is needed
        guard size.width > maxDimension || size.height > maxDimension else {
            return image
        }

        let scale: CGFloat
        if size.width > size.height {
            scale = maxDimension / size.width
        } else {
            scale = maxDimension / size.height
        }

        let newSize = CGSize(
            width: size.width * scale,
            height: size.height * scale
        )

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// Compress an image to JPEG data with the specified quality
    func compress(image: UIImage, quality: CGFloat = Config.jpegQuality) -> Data? {
        image.jpegData(compressionQuality: quality)
    }

    /// Generate a thumbnail from image data
    func generateThumbnail(from data: Data, maxSize: CGFloat = Config.thumbnailSize) -> Data? {
        guard let image = UIImage(data: data) else {
            return nil
        }

        let thumbnail = resize(image: image, maxDimension: maxSize)
        return thumbnail.jpegData(compressionQuality: 0.7)
    }

    /// Generate a thumbnail from a UIImage
    func generateThumbnail(from image: UIImage, maxSize: CGFloat = Config.thumbnailSize) -> Data? {
        let thumbnail = resize(image: image, maxDimension: maxSize)
        return thumbnail.jpegData(compressionQuality: 0.7)
    }

    /// Prepare an image for upload by resizing and compressing
    func prepareForUpload(image: UIImage, maxDimension: CGFloat = Config.maxUploadDimension, quality: CGFloat = Config.jpegQuality) -> Data? {
        let resized = resize(image: image, maxDimension: maxDimension)
        return compress(image: resized, quality: quality)
    }

    /// Create a UIImage from data, handling various formats including HEIC
    func createImage(from data: Data) -> UIImage? {
        UIImage(data: data)
    }

    /// Create a 1x1 pixel test image
    func createTestImage() -> Data? {
        let size = CGSize(width: 1, height: 1)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return image.pngData()
    }
}
