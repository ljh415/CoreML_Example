import SwiftUI
import PhotosUI

struct ContentView: View {
    @EnvironmentObject var viewModel: ImageProcessingViewModel  // ✅ ViewModel 주입
    @State private var selectedItem: PhotosPickerItem? = nil // PhotosPicker에서 선택된 아이템 저장

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 10) { // 기존 간격 유지
                // App Title
                Text("Huray App")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(Color.purple)
                    .padding(.top, geometry.safeAreaInsets.top * 0.1)
                    .zIndex(1)
                
                // ✅ PhotosPicker에서 이미지 선택
                PhotosPicker(selection: $selectedItem, matching: .images) {
                    VStack {
                        if let processedImage = viewModel.processedImage {
                            Image(uiImage: processedImage)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 300)
                                .cornerRadius(10)
                        }
                        else if let image = viewModel.selectedImage {
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 300)
                                .cornerRadius(10)
                        } else {
                            Rectangle()
                                .fill(Color.gray.opacity(0.2))
                                .frame(height: 300)
                                .cornerRadius(10)
                                .overlay(Text("이미지를 선택하세요").foregroundColor(.gray))
                        }
                    }
                }
                .onChange(of: selectedItem) { newItem in
                    if let newItem = newItem {
                        Task {
                            if let imageData = try? await newItem.loadTransferable(type: Data.self),
                               let uiImage = UIImage(data: imageData) {
                                viewModel.setSelectedImage(uiImage)  // ✅ ViewModel의 메서드 호출
                            }
                        }
                    }
                }
                .padding()

                // Run Model Button
                Button(action: {
                    if let selectedImage = viewModel.selectedImage, let cgImage = selectedImage.cgImage {
                        viewModel.processImage(cgImage)
                    }
                }) {
                    Text("Run Model")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                        .padding()
                        .frame(maxWidth: .infinity)
                        .background(Color.purple)
                        .cornerRadius(10)
                }
                .padding(.horizontal)

                // Classification Results (Top-5)
                if !viewModel.classificationResults.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Classification 결과 (Top-5)")
                                .font(.headline)
                                .foregroundColor(.purple)

                            ForEach(viewModel.classificationResults.keys.sorted(), id: \.self) { key in
                                VStack(alignment: .leading) {
                                    Text(key)
                                        .font(.headline)
                                        .foregroundColor(.purple)

                                    ForEach(viewModel.classificationResults[key] ?? [], id: \.0) { (label, confidence) in
                                        Text("\(label): \(confidence * 100, specifier: "%.2f")%")
                                            .font(.subheadline)
                                    }
                                }
                                .padding(.vertical, 5)
                            }
                        }
                        .padding()
                    }
                    .frame(height: geometry.size.height * 0.2)
                }

                // Inference Time Display
                VStack(spacing: 4) {
                    Text("Detection Time: \(viewModel.detectionInferenceTime)")  // ✅ Detection 시간 추가
                    Text("Classification Time (Avg per Object): \(viewModel.classificationInferenceTime)")  // ✅ Classification 평균 처리 시간 추가
                    Text("End-to-End Inference Time: \(viewModel.endToEndInferenceTime)")  // ✅ End-to-End 시간 추가
                }
                .font(.headline)
                .foregroundColor(.purple)
                .padding()
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .edgesIgnoringSafeArea(.bottom)
        }
    }
}
