import Foundation
import UIKit
import Vision

/// OCR only the image selected by the user. No screenshot or recognized text is persisted.
enum PartsHistoryService {
    static func recognize(_ image: UIImage) throws -> [String] {
        guard let cgImage = image.cgImage else {
            throw NSError(domain: "PanicAnalyzer.PartsHistory", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: Loc.s(
                            "Không đọc được ảnh. Hãy chụp lại màn hình Giới thiệu.",
                            "Could not read the image. Take another screenshot of About.",
                            "无法读取图片，请重新截取“关于本机”页面。")])
        }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.minimumTextHeight = 0.008
        let preferred = ["vi-VN", "en-US", "zh-Hans"]
        if let supported = try? request.supportedRecognitionLanguages() {
            let available = preferred.filter { supported.contains($0) }
            if !available.isEmpty { request.recognitionLanguages = available }
        }
        try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
        return (request.results ?? [])
            .sorted { a, b in
                if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.025 {
                    return a.boundingBox.midY > b.boundingBox.midY
                }
                return a.boundingBox.minX < b.boundingBox.minX
            }
            .compactMap { $0.topCandidates(1).first?.string }
    }
}
