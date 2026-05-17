//
//  ScreenCapturer.swift
//  Mindflow — snapshot the frontmost window as PNG data.
//

import AppKit
import Foundation
import ScreenCaptureKit

enum ScreenCapturerError: Error {
    case noFrontmostApp
    case noWindowsForFrontmostApp
    case pngConversionFailed
}

@MainActor
final class ScreenCapturer {
    func captureFrontmostWindow() async throws -> Data {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            throw ScreenCapturerError.noFrontmostApp
        }
        let pid = frontmostApp.processIdentifier

        let content = try await SCShareableContent.current
        let windows = content.windows.filter { window in
            window.owningApplication?.processID == pid
                && window.isOnScreen
                && window.frame.width > 200
                && window.frame.height > 200
        }
        guard let window = windows.first else {
            throw ScreenCapturerError.noWindowsForFrontmostApp
        }

        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.width = Int(window.frame.width * 2)
        config.height = Int(window.frame.height * 2)

        let cgImage = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: config
        )

        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw ScreenCapturerError.pngConversionFailed
        }
        return pngData
    }
}
