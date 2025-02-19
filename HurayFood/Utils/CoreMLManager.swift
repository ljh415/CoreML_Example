//
//  CoreMLManager.swift
//  HurayFood
//
//  Created by Jae Ho Lee on 2/10/25.
//

import Foundation

import CoreML
import Vision
import SwiftUI

import UIKit

class CoreMLManager {
    static let shared = CoreMLManager()

    private var detectionModel: det
    private var classificationModel: cls
    
    private init() {
        do {
            self.detectionModel = try det(configuration: MLModelConfiguration())
            self.classificationModel = try cls(configuration: MLModelConfiguration())
        } catch {
            fatalError("CoreML 모델 로드 실패: \(error)")
        }
    }
    
    /// Step 1: Detection 실행
    func detectObjects(in cgImage: CGImage, completion: @escaping ([CGRect], [Float], CGRect) -> Void) {
        
        let (optionalResizedImage, letterboxRect) = letterboxResize(cgImage, targetSize: CGSize(width: 640, height: 640))
        
        guard let resizedImage = optionalResizedImage else {
            print("preprocess/resize 실패")
            return
        }
         
        guard let pixelBuffer = convertToPixelBuffer(from: resizedImage) else {
            print("CGImage -> CVPixelBuffer 변환 실패")
            return
        }
        
        let input = detInput(
            image: pixelBuffer,
            iouThreshold: 0.5,
            confidenceThreshold: 0.25
        )
        
        do {
            let prediction = try detectionModel.prediction(input: input)
            let confidenceArray = prediction.confidence
            let coordinatesArray = prediction.coordinates
            
            var boundingBoxes: [CGRect] = []
            var confidenceScores: [Float] = []
            
            let numBoxes = confidenceArray.shape[0].intValue
            let confidenceData = confidenceArray.dataPointer.bindMemory(to: Float.self, capacity: numBoxes * 2)
            let coordinatesData = coordinatesArray.dataPointer.bindMemory(to: Float.self, capacity: numBoxes * 4)
            
            for i in 0..<numBoxes{
                print("i: \(i)")
                let confidence = confidenceData[i*2]
                print("confidence: \(confidence)")
                
                if confidence > 0.25 {
                    let cx = coordinatesData[i * 4]
                    let cy = coordinatesData[i * 4 + 1]
                    let width = coordinatesData[i * 4 + 2]
                    let height = coordinatesData[i * 4 + 3]
                    
                    let originalSize = CGSize(width: cgImage.width, height: cgImage.height)
                    let bbox = restoreBoundingBox(
                        CGRect(
                            x: CGFloat((cx - width / 2.0) * 640),
                            y: CGFloat((cy - height / 2.0) * 640),
                            width: CGFloat(width * 640),
                            height: CGFloat(height * 640)
                        ),
                        from: CGSize(width: 640, height: 640),
                        to:originalSize,
                        letterboxRect: letterboxRect
                    )
                    boundingBoxes.append(bbox)
                    
                    confidenceScores.append(confidence)
                }
            }
            
            DispatchQueue.main.async {
                completion(boundingBoxes, confidenceScores, letterboxRect)
            }
        } catch {
            print("Detection 오류 발생: \(error)")
        }
    }
    
    /// classification
    func classify(cgImage: CGImage, uiImageSize: CGSize, boundingBox: CGRect, completion: @escaping (String, [String: Double]) -> Void) {

        /// bbox 수정
        guard let croppedImage = cropImage(cgImage: cgImage, uiImageSize: uiImageSize, bbox: boundingBox) else {
            print("❌ 이미지 크롭 실패: \(boundingBox)")
            return
        }
        
        guard let resizedImage = resizeCGImage(croppedImage, to: CGSize(width: 480, height: 480)) else {
            print("이미지 Resize 실패")
            return
        }
        
        guard let pixelBuffer = convertToPixelBuffer(from: resizedImage) else {
            print("이미지 크롭/CVPixelBuffer 변환 실패")
            return
        }
        
        let input = clsInput(x_1: pixelBuffer)
        
        do {
            let prediction = try classificationModel.prediction(input: input)
            completion(prediction.classLabel, prediction.classLabel_probs)
        } catch {
            print("Classification 오류 발생: \(error)")
        }
    }
    
    private func resizeCGImage(_ image: CGImage, to size: CGSize) -> CGImage? {
        let width = Int(size.width)
        let height = Int(size.height)
        let bitsPerComponent = image.bitsPerComponent
        let bytesPerRow = image.bytesPerRow
        let colorSpace = image.colorSpace
        let bitmapInfo = image.bitmapInfo
        
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: 0,
            space: colorSpace!,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }
        
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        
        return context.makeImage()
    }
    
    private func cropImage(cgImage: CGImage, uiImageSize: CGSize, bbox: CGRect) -> CGImage? {
        let uiWidth = uiImageSize.width
        let uiHeight = uiImageSize.height
        let cgWidth = CGFloat(cgImage.width)
        let cgHeight = CGFloat(cgImage.height)

        // ✅ 크기 비율 맞추기 (UIImage → CGImage)
        let scaleX = cgWidth / uiWidth
        let scaleY = cgHeight / uiHeight

        let x = bbox.origin.x * scaleX
        let y = bbox.origin.y * scaleY
        let width = bbox.width * scaleX
        let height = bbox.height * scaleY

        // ✅ UIKit 좌표 (Top-Left) → CoreGraphics 좌표 (Bottom-Left)
        let flippedY = cgHeight - y - height

        let convertedBBox = CGRect(x: x, y: flippedY, width: width, height: height)

        return cgImage.cropping(to: convertedBBox)
    }

    
    private func convertToPixelBuffer(from cgImage: CGImage) -> CVPixelBuffer? {
        let width = cgImage.width
        let height = cgImage.height
        
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }
        
        CVPixelBufferLockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0))
        defer { CVPixelBufferUnlockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0)) }
        
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else {
            print("CGContext 생성 실패")
            return nil
        }
        
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1.0, y: -1.0)
        
        context.draw(cgImage, in: CGRect(x:0, y: 0, width: width, height: height))
        
        return buffer
    }
    
    func letterboxResize(_ image: CGImage, targetSize: CGSize) -> (CGImage?, CGRect) {
        let originalWidth = CGFloat(image.width)
        let originalHeight = CGFloat(image.height)
        let targetWidth = targetSize.width
        let targetHeight = targetSize.height
        
        // YOLO 모델이 요구하는 해상도 기준으로 스케일 비율 유지
        let scale = min(targetWidth / originalWidth, targetHeight / originalHeight)
        let newWidth = originalWidth * scale
        let newHeight = originalHeight * scale
        
        // 패딩 계산 (중앙 정렬)
        let dx = (targetWidth - newWidth) / 2.0
        let dy = (targetHeight - newHeight) / 2.0
        
        // CoreGraphics로 새로운 이미지 생성
        guard let context = CGContext(
            data: nil,
            width: Int(targetWidth),
            height: Int(targetHeight),
            bitsPerComponent: image.bitsPerComponent,
            bytesPerRow: 0,
            space: image.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: image.bitmapInfo.rawValue
        ) else {
            return (nil, .zero)
        }
        
        context.setFillColor(CGColor(gray: 0, alpha:1.0))  // YOLO는 기본적으로 검은색 패딩
        context.fill(CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        
        // 원본 비율 유지하며 중앙 배치
        let drawRect = CGRect(x: dx, y: dy, width: newWidth, height: newHeight)
        context.draw(image, in: drawRect)
        
        let resizedImage = context.makeImage()
        
        return (resizedImage, drawRect)
    }
    
    private func restoreBoundingBox(_ bbox: CGRect, from targetSize: CGSize, to originalSize: CGSize, letterboxRect: CGRect) -> CGRect {
        let originalWidth = originalSize.width
        let originalHeight = originalSize.height
        let targetWidth = targetSize.width
        let targetHeight = targetSize.height

        // Letterbox 처리된 이미지의 scale 계산
        let scale = min(targetWidth / originalWidth, targetHeight / originalHeight)

        // Letterbox padding을 고려한 보정
        let x_min = (bbox.origin.x - letterboxRect.origin.x) / scale
        let y_min = (bbox.origin.y - letterboxRect.origin.y) / scale
        let width = bbox.width / scale
        let height = bbox.height / scale

        // 원본 이미지 크기 범위 내에서 제한
        let restoredBox = CGRect(
            x: max(0, min(x_min, originalWidth - 1)),
            y: max(0, min(y_min, originalHeight - 1)),
            width: min(width, originalWidth - x_min),
            height: min(height, originalHeight - y_min)
        )

        return restoredBox
    }
}
