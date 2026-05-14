// NemoNoise/Models/ASRError.swift
import Foundation

enum ASRError: Error {
    case modelNotFound
    case audioCaptureFailed(String)
    case invalidPythonPath
    case socketDisconnected
    case engineUnavailable
    case engineInitFailed
}

enum CloudASRError: Error {
    case apiKeyNotSet
    case authenticationFailed
    case requestTimeout
    case serverError(Int)
    case invalidResponse
}
