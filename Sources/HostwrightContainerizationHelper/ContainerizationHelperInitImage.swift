import Containerization

enum ContainerizationHelperInitImage {
    static func require(
        configuration: ContainerizationHelperConfiguration,
        imageStore: ImageStore
    ) async throws -> Containerization.Image {
        var images = try await imageStore.list()
        if !images.contains(where: { $0.reference == configuration.initImageReference }) {
            _ = try await imageStore.load(from: configuration.initImageLayoutURL)
            images = try await imageStore.list()
        }
        guard let image = images.first(where: { $0.reference == configuration.initImageReference }),
              image.descriptor.digest == configuration.initImageDescriptorDigest,
              try await image.descriptor(for: .current).digest == configuration.initImageVariantDigest else {
            throw ContainerizationHelperConfigurationError.assetDigestMismatch
        }
        return image
    }
}
