import SwiftUI

/// QEMU 로그 출력 뷰
struct LogView: View {
    @ObservedObject var viewModel: SandboxViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("실행 로그")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    viewModel.logOutput = ""
                } label: {
                    Label("지우기", systemImage: "trash")
                }
                .disabled(viewModel.logOutput.isEmpty)

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(viewModel.logOutput, forType: .string)
                } label: {
                    Label("복사", systemImage: "doc.on.doc")
                }
                .disabled(viewModel.logOutput.isEmpty)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    Text(viewModel.logOutput.isEmpty ? "로그가 비어있습니다." : viewModel.logOutput)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                        .id("logBottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .onChange(of: viewModel.logOutput) { _, _ in
                    withAnimation {
                        proxy.scrollTo("logBottom", anchor: .bottom)
                    }
                }
            }
        }
        .padding(24)
        .navigationTitle("로그")
    }
}
