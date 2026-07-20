import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct SwingVideoPickerLoader {
    func loadSourceURL(from item: PhotosPickerItem) async throws -> URL {
        guard let video = try await item.loadTransferable(type: PickedVideo.self) else {
            throw ImportError.noVideoData
        }

        return video.url
    }

    func removeTemporarySource(at url: URL) {
        guard url.path().contains("/PickedSwingVideos/") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    enum ImportError: Error {
        case noVideoData
    }
}

private struct PickedVideo: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { receivedFile in
            let destinationURL = FileManager.default.temporaryDirectory
                .appending(path: "PickedSwingVideos", directoryHint: .isDirectory)
                .appending(path: UUID().uuidString)
                .appendingPathExtension(receivedFile.file.pathExtension.isEmpty ? "mov" : receivedFile.file.pathExtension)

            try FileManager.default.createDirectory(
                at: destinationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: nil
            )
            try FileManager.default.copyItem(at: receivedFile.file, to: destinationURL)

            return PickedVideo(url: destinationURL)
        }
    }
}
