import Foundation
import Vision

enum ClipboardImageRecognition {
    static func text(in data: Data) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if #available(macOS 13, *) { request.automaticallyDetectsLanguage = true }
        try VNImageRequestHandler(data: data).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func qrCodes(in data: Data) throws -> String {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(data: data).perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue).joined(separator: "\n")
    }
}
