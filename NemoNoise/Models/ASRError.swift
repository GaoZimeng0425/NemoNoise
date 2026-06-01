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

enum AppleSpeechError: Error, Equatable {
    case siriDisabled
    case recognizerUnavailable
}
