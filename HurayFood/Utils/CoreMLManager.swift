//
//  CoreMLManager.swift
//  HurayFood
//
//  Created by Jae Ho Lee on 2/10/25.
//

import Foundation

import Accelerate
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
            let det_config = MLModelConfiguration()
            det_config.computeUnits = .all
            det_config.allowLowPrecisionAccumulationOnGPU = true
                        
            
            let cls_config = MLModelConfiguration()
            cls_config.computeUnits = .cpuAndGPU
            cls_config.allowLowPrecisionAccumulationOnGPU = true
            
            self.detectionModel = try det(configuration: det_config)
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
                            x: CGFloat(cx),
                            y: CGFloat(cy),
                            width: CGFloat(width),
                            height: CGFloat(height)
                        ),
                        from: CGSize(width: 640, height: 640),
                        to:originalSize,
                        letterboxRect: letterboxRect
                    )
                    print("restored bbox: \(bbox)")
                    boundingBoxes.append(bbox)
                    
                    confidenceScores.append(confidence)
                    print()
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

        let convertedBBox = CGRect(x: x, y: y, width: width, height: height)

        return cgImage.cropping(to: convertedBBox)
    }

    
    private func convertToPixelBuffer(from cgImage: CGImage) -> CVPixelBuffer? {
        let width = cgImage.width
        let height = cgImage.height
        
        // 픽셀 버퍼 생성
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,          // CGImage와 호환되도록 설정
            kCVPixelBufferCGBitmapContextCompatibilityKey: true   // CGBitmapContext와 호환되도록 설정
        ]
        
        // 버퍼 생성요청 -> 생성되는 버퍼는 pixelBuffer 변수에 저장
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        )
        
        // 픽셀버퍼 생성 확인
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }
        
        // 메모리 잠금 + 쓰기 가능하도록 설정
        CVPixelBufferLockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0))
        defer { CVPixelBufferUnlockBaseAddress(buffer, CVPixelBufferLockFlags(rawValue: 0)) }
        
        // 이미지를 그릴 수 있는 그래픽 컨텍스트 생성전
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),  // 한 줄당 바이트 크기 자동 설정
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else {
            print("CGContext 생성 실패")
            return nil
        }
        
        context.draw(cgImage, in: CGRect(x:0, y: 0, width: width, height: height))
        
        // ✅ Accelerate를 활용한 벡터 연산 적용
        guard let baseAddress = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else {
            print("메모리 접근 실패")
            return nil
        }

        let totalPixels = width * height * 4  // BGRA (4채널)
        
        // ✅ 입력 및 출력 배열 생성
        var inputPixels = [Float](repeating: 0, count: totalPixels)
        var outputPixels = [Float](repeating: 0, count: totalPixels)

        // UInt8 → Float 변환 (0~255 → 0~1)
        vDSP_vfltu8(baseAddress, 1, &inputPixels, 1, vDSP_Length(totalPixels))

        // ✅ 벡터 연산으로 -1~1 정규화
        var scale: Float = 2.0 / 255.0
        var bias: Float = -1.0
        vDSP_vsmsa(inputPixels, 1, &scale, &bias, &outputPixels, 1, vDSP_Length(totalPixels))

        // -1~1 → 0~255 변환
        var inverseScale: Float = 127.5
        var inverseBias: Float = 127.5
        vDSP_vsmsa(outputPixels, 1, &inverseScale, &inverseBias, &inputPixels, 1, vDSP_Length(totalPixels))

        // Float → UInt8 변환
        vDSP_vfixu8(inputPixels, 1, baseAddress, 1, vDSP_Length(totalPixels))

        
        return buffer
    }
    
    func letterboxResize(_ image: CGImage, targetSize: CGSize) -> (CGImage?, CGRect) {
        // 원본 및 목표 크기 가져오기
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
        // 비어있는 이미지 생성 후에
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
        
        context.setFillColor(CGColor(red: 114.0/255.0, green: 114.0/255.0, blue: 114.0/255.0, alpha: 1.0))
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
        
        let x_out = (bbox.origin.x - bbox.width / 2.0) * targetWidth
        let y_out = (bbox.origin.y - bbox.height / 2.0) * targetHeight
        let width_out = bbox.width * targetWidth
        let height_out = bbox.height * targetHeight

        // Letterbox 처리된 이미지의 scale 계산
        let scale = min(targetWidth / originalWidth, targetHeight / originalHeight)

        // Letterbox padding을 고려한 보정
        let x_min = (x_out - letterboxRect.origin.x) / scale
        let y_min = (y_out - letterboxRect.origin.y) / scale
        let width = width_out / scale
        let height = height_out / scale

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
