import UIKit
import SwiftUI
import UniformTypeIdentifiers

class ShareViewController: UIViewController {
    private var hostingController: UIHostingController<ShareView>?

    override func viewDidLoad() {
        super.viewDidLoad()

        let shareView = ShareView(
            extensionContext: extensionContext,
            loadImage: loadImage
        )

        let hostingController = UIHostingController(rootView: shareView)
        self.hostingController = hostingController

        addChild(hostingController)
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])

        hostingController.didMove(toParent: self)
    }

    private func loadImage() async throws -> (Data, String) {
        guard let extensionItems = extensionContext?.inputItems as? [NSExtensionItem] else {
            throw ImageHostError.invalidResponse
        }

        for item in extensionItems {
            guard let attachments = item.attachments else { continue }

            for provider in attachments {
                // Try different image type identifiers
                let imageTypes = [
                    UTType.image.identifier,
                    UTType.jpeg.identifier,
                    UTType.png.identifier,
                    UTType.heic.identifier,
                    UTType.gif.identifier,
                    UTType.webP.identifier
                ]

                for typeIdentifier in imageTypes {
                    if provider.hasItemConformingToTypeIdentifier(typeIdentifier) {
                        let (data, filename) = try await loadData(from: provider, typeIdentifier: typeIdentifier)
                        return (data, filename)
                    }
                }
            }
        }

        throw ImageHostError.invalidResponse
    }

    private func loadData(from provider: NSItemProvider, typeIdentifier: String) async throws -> (Data, String) {
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
                if let error = error {
                    continuation.resume(throwing: ImageHostError.networkError(underlying: error))
                    return
                }

                guard let data = data else {
                    continuation.resume(throwing: ImageHostError.invalidResponse)
                    return
                }

                // Generate filename
                let filename = self.generateFilename(for: typeIdentifier)

                // Convert HEIC to JPEG for better compatibility
                if typeIdentifier == UTType.heic.identifier {
                    if let image = UIImage(data: data),
                       let jpegData = image.jpegData(compressionQuality: Config.jpegQuality) {
                        let jpegFilename = filename.replacingOccurrences(of: ".heic", with: ".jpg")
                        continuation.resume(returning: (jpegData, jpegFilename))
                        return
                    }
                }

                continuation.resume(returning: (data, filename))
            }
        }
    }

    private func generateFilename(for typeIdentifier: String) -> String {
        let timestamp = Int(Date().timeIntervalSince1970)

        switch typeIdentifier {
        case UTType.png.identifier:
            return "image_\(timestamp).png"
        case UTType.gif.identifier:
            return "image_\(timestamp).gif"
        case UTType.webP.identifier:
            return "image_\(timestamp).webp"
        case UTType.heic.identifier:
            return "image_\(timestamp).heic"
        default:
            return "image_\(timestamp).jpg"
        }
    }
}
