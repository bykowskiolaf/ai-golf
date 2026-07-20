//
//  ai_golfTests.swift
//  ai-golfTests
//
//  Created by Olaf Bykowski on 20/07/2026.
//

import Testing
import Foundation
@testable import ai_golf

struct ai_golfTests {

    @Test @MainActor func initialStateIsEmpty() {
        let viewModel = SwingImportViewModel(importDirectory: Self.temporaryDirectory())

        #expect(viewModel.state == SwingImportViewModel.State.empty)
    }

    @Test @MainActor func successfulImportProducesPlayableLocalURL() async throws {
        let importDirectory = Self.temporaryDirectory()
        let sourceURL = try Self.makeVideoFile(named: "source.mov")
        let viewModel = SwingImportViewModel(importDirectory: importDirectory)

        await viewModel.importVideo { sourceURL }

        guard case .ready(let swing) = viewModel.state else {
            Issue.record("Expected ready state")
            return
        }

        #expect(swing.localVideoURL.path().hasPrefix(importDirectory.path()))
        #expect(FileManager.default.fileExists(atPath: swing.localVideoURL.path()))
        #expect(try Data(contentsOf: swing.localVideoURL) == Data("video".utf8))
    }

    @Test @MainActor func failedImportProducesErrorState() async {
        let viewModel = SwingImportViewModel(importDirectory: Self.temporaryDirectory())

        await viewModel.importVideo {
            throw TestImportError.failed
        }

        guard case .failed(let message) = viewModel.state else {
            Issue.record("Expected failed state")
            return
        }

        #expect(message == "The video could not be imported. Please try another video.")
    }

    @Test @MainActor func replacingVideoUpdatesSelectedVideoAndRemovesPreviousFile() async throws {
        let importDirectory = Self.temporaryDirectory()
        let firstSourceURL = try Self.makeVideoFile(named: "first.mov", contents: "first")
        let secondSourceURL = try Self.makeVideoFile(named: "second.mov", contents: "second")
        let viewModel = SwingImportViewModel(importDirectory: importDirectory)

        await viewModel.importVideo { firstSourceURL }
        guard case .ready(let firstSwing) = viewModel.state else {
            Issue.record("Expected first ready state")
            return
        }

        await viewModel.importVideo { secondSourceURL }
        guard case .ready(let secondSwing) = viewModel.state else {
            Issue.record("Expected second ready state")
            return
        }

        #expect(firstSwing.localVideoURL != secondSwing.localVideoURL)
        #expect(!FileManager.default.fileExists(atPath: firstSwing.localVideoURL.path()))
        #expect(FileManager.default.fileExists(atPath: secondSwing.localVideoURL.path()))
        #expect(try Data(contentsOf: secondSwing.localVideoURL) == Data("second".utf8))
    }

    private enum TestImportError: Error {
        case failed
    }

    private static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "SwingImportViewModelTests")
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    }

    private static func makeVideoFile(named name: String, contents: String = "video") throws -> URL {
        let directory = temporaryDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        let url = directory.appending(path: name)
        try Data(contents.utf8).write(to: url)
        return url
    }
}
