//
//  ImageProcessingViewModel.swift
//  HurayFood
//
//  Created by Jae Ho Lee on 2/10/25.
//

import Foundation

import SwiftUI
import CoreML

class ImageProcessingViewModel: ObservableObject {
    @Published var selectedImage: UIImage? = nil
    @Published var processedImage: UIImage? = nil // bbox 그린 이미지
    @Published var detectedBoxes: [CGRect] = []
    @Published var confidenceScores: [Float] = []
    @Published var classificationResults: [String: [(String, Double)]] = [:]
    @Published var detectionInferenceTime: String = "-- ms"
    @Published var classificationInferenceTime: String = "-- ms"
    @Published var endToEndInferenceTime: String = "-- ms"
    
    // 선택한 이미지 업데이트
    func setSelectedImage(_ image: UIImage) {
        DispatchQueue.main.async {
            self.selectedImage = image
            self.processedImage = nil
        }
    }
    
    // CoreML
    func processImage(_ cgImage: CGImage) {
        let startTime = Date()
        let detectionStartTime = Date()
        
        // Step1: Object Detection
        CoreMLManager.shared.detectObjects(in: cgImage) { boxes, scores, letterboxRect in
            let detectionElapsedTime = Date().timeIntervalSince(detectionStartTime) * 1000
            DispatchQueue.main.async {
                self.detectionInferenceTime = String(format: "%.2f ms", detectionElapsedTime)
                
                if boxes.isEmpty {
                    self.endToEndInferenceTime = "No Objects detected"
                    return
                }
                // bbox 복원 letterbox 후처리
                let originalSize = CGSize(width: cgImage.width, height: cgImage.height)
                let targetSize = CGSize(width: 640, height: 640)
                
                self.detectedBoxes = boxes
                self.confidenceScores = scores
                self.classificationResults = [:]
                
                guard let selectedImage = self.selectedImage else {
                    print("❌ selectedImage가 nil입니다. classify() 호출을 건너뜁니다.")
                    return
                }
                
                let classificationStartTime = Date()        // classification 시작 시간
                var classificationDurations: [Double] = []  // 개별 classification 수행 시간
                let dispatchGroup = DispatchGroup()         // 모든 classification이 끝날때 까지 기다림
                var classifiedResults: [String: [(String, Double)]] = [:]

//                 Step2: 각 bbox에 Classification
                for (index, box) in boxes.enumerated() {
                    dispatchGroup.enter()  // classifiation 시작 전에 그룹에 추가
                    let objStartTime = Date()
                    
                    CoreMLManager.shared.classify(
                        cgImage: cgImage,
                        uiImageSize: selectedImage.size,
                        boundingBox: box
                    ) { label, probs in
                        DispatchQueue.main.async {
                            let elapsedTime = Date().timeIntervalSince(objStartTime) * 1000
                            classificationDurations.append(elapsedTime)
                            
                            let sortedResults = probs.sorted { $0.value > $1.value }
                                    .prefix(5)
                                    .map { ($0.key, $0.value) }
                            
                            let objectKey = String(format: "Object %02d", index + 1)
                            classifiedResults[objectKey] = sortedResults
                            dispatchGroup.leave()  // classification 완료 후 그룹에서 제거
                            }
                        }
                    }
                
                
                // 모든 classification이 끝난 후 평균 처리 시간과 End-to-End 시간 계산
                dispatchGroup.notify(queue: .main) {
                    let totalClassificationTime = classificationDurations.reduce(0, +)
                    
                    let averageClassificationTime = totalClassificationTime / Double(classificationDurations.count)
                    
                    self.classificationInferenceTime = String(format: "%.2f ms", averageClassificationTime)
                    
                    let totalTime = Date().timeIntervalSince(startTime) * 1000
                    self.endToEndInferenceTime = String(format: "%.2f ms", totalTime)
                    
                    self.classificationResults = classifiedResults
                    
                    if let uiImage = self.selectedImage {
                        self.processedImage = self.drawBoundingBoxes(
                            on: uiImage,
                            boxes: boxes,
                            scores: scores,
                            results: self.classificationResults
                        )
                    }
                }
            }
        }
    }

    private func drawBoundingBoxes(on image: UIImage, boxes: [CGRect], scores: [Float], results: [String: [(String, Double)]]) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: image.size)
        return renderer.image { ctx in
            image.draw(at: .zero)
            
            ctx.cgContext.setLineWidth(3)
            ctx.cgContext.setStrokeColor(UIColor.red.cgColor)
            
            for (i, box) in boxes.enumerated() {
                let adjustedY = image.size.height - box.origin.y - box.height
                let adjustedBox = CGRect(x: box.origin.x, y: adjustedY, width: box.width, height: box.height)
                
                ctx.cgContext.stroke(adjustedBox)
                
                // ✅ results에서 가장 확률이 높은 라벨 가져오기
                let objectKey = String(format: "Object %02d", i + 1)
                let classLabel = results[objectKey]?.first?.0 ?? "Unknown"
                
                let topResult = results[objectKey]?.first
                let classConfidence = topResult?.1 ?? 0.0  // Classification Confidence
                let scoreText = String(format: "%.2f", classConfidence)
                
                // ✅ 표시할 텍스트 구성
                let text = "\(classLabel) (\(scoreText))"
                
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 14, weight: .bold),
                    .foregroundColor: UIColor.red
                ]
                
                // ✅ 텍스트 위치를 box 위쪽에 배치
                let textPosition = CGPoint(x: box.origin.x, y: max(adjustedY - 20, 5))
                text.draw(at: textPosition, withAttributes: attributes)
            }
        }
    }
}
