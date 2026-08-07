import OllamaBarCore
import SwiftUI

/// Everything that has to be read rather than glanced at.
///
/// The panel closes the moment it loses focus, so reading a completion there is impossible. This
/// is an ordinary window you can park next to the editor. The tabs are four views of one exchange,
/// not four screens.
struct OutputWindow: View {
    let model: AppModel

    @State private var tab: Tab = .output
    @State private var follow = true

    enum Tab: String, CaseIterable, Identifiable {
        case output = "Output"
        case reasoning = "Reasoning"
        case prompt = "Prompt"
        case tools = "Tools"

        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let exchange {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(10)

                Divider()
                transcript(for: exchange)
                Divider()
                statusLine(for: exchange)
            } else {
                ContentUnavailableView(
                    "Nothing captured yet",
                    systemImage: "text.append",
                    description: Text(
                        model.settings.proxyEnabled
                            ? "Point a client at the proxy port and its traffic shows up here."
                            : "Turn on interception in Settings to capture prompts and output."
                    )
                )
            }
        }
        .frame(minWidth: 460, minHeight: 320)
        .navigationTitle(exchange?.model ?? "Output")
    }

    /// The newest exchange that actually carries text — while a request is running that is the
    /// live one, and after it finishes the window keeps showing it rather than emptying.
    private var exchange: ProxiedExchange? {
        model.monitor.activeExchange
            ?? model.monitor.exchanges.last { !$0.output.isEmpty || !$0.reasoning.isEmpty }
            ?? model.monitor.exchanges.last
    }

    private func transcript(for exchange: ProxiedExchange) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text(for: exchange).isEmpty ? "—" : text(for: exchange))
                    .font(.system(size: 12, design: .monospaced))
                    .italic(tab == .reasoning)
                    .textSelection(.enabled)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .id("body")
            }
            .onChange(of: text(for: exchange)) {
                guard follow else { return }
                withAnimation { proxy.scrollTo("body", anchor: .bottom) }
            }
        }
    }

    private func text(for exchange: ProxiedExchange) -> String {
        switch tab {
        case .output: exchange.output
        case .reasoning: exchange.reasoning
        case .prompt: exchange.prompt ?? ""
        case .tools: exchange.toolCalls.joined(separator: "\n")
        }
    }

    private func statusLine(for exchange: ProxiedExchange) -> some View {
        HStack(spacing: 14) {
            if let rate = model.monitor.throughput?.tokensPerSecond, exchange.isActive {
                Text(Format.rate(rate))
            }
            if let tokens = exchange.completionTokens ?? model.monitor.throughput?.tokensDecoded,
               tokens > 0 {
                Text("\(tokens) tok")
            }
            Text(Format.elapsed(
                (exchange.finishedAt ?? .now).timeIntervalSince(exchange.startedAt)
            ))
            if let client = exchange.client {
                Text(client).lineLimit(1)
            }
            Spacer()
            Toggle("Follow", isOn: $follow)
                .toggleStyle(.checkbox)
            if exchange.outputTruncated {
                Text("truncated")
                    .foregroundStyle(.orange)
            }
        }
        .font(Panel.Typography.body)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
    }
}
