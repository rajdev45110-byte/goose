import SwiftUI

struct CoachChatScreen: View {
  @ObservedObject var chat: OpenAICoachChatModel
  @ObservedObject var healthStore: HealthDataStore
  @ObservedObject var appModel: GooseAppModel
  @Binding var draft: String
  let scrollToBottomRequestID: Int
  @FocusState private var composerFocused: Bool

  private let suggestions = [
    CoachPromptSuggestion(
      id: "blockers",
      title: "Find blockers",
      detail: "Score readiness, stale inputs, and the next fix.",
      prompt: "What is blocking today's scores?",
      systemImage: "chart.bar.xaxis"
    ),
    CoachPromptSuggestion(
      id: "recovery",
      title: "Read recovery",
      detail: "A concise recovery take with missing data called out.",
      prompt: "Summarize my recovery signals and what is missing.",
      systemImage: "waveform.path.ecg"
    ),
    CoachPromptSuggestion(
      id: "capture",
      title: "Next capture",
      detail: "What to collect next to improve confidence.",
      prompt: "What should I capture next to improve Coach confidence?",
      systemImage: "dot.radiowaves.left.and.right"
    ),
  ]

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          if !GooseCoachPolicy.remoteExecutionEnabled {
            CoachRemoteDisabledNotice(
              hasHistory: !chat.messages.isEmpty,
              hasStoredCredentials: chat.hasStoredCredentials,
              clearHistory: chat.clearLocalConversation,
              forgetCredentials: chat.forgetStoredCredentials
            )
          }

          if chat.streamState != .idle {
            CoachConnectionStrip(streamState: chat.streamState)
          }

          ForEach(chat.messages) { message in
            CoachMessageBubble(message: message)
              .id(message.id)
          }

          if chat.messages.count <= 1, GooseCoachPolicy.remoteExecutionEnabled {
            CoachSuggestionStack(suggestions: suggestions) { suggestion in
              composerFocused = false
              draft = ""
              send(prompt: suggestion.prompt)
            }
          }

          if let errorMessage = chat.errorMessage, !errorMessage.isEmpty {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
              .font(.footnote)
              .foregroundStyle(.red)
              .padding(.horizontal, 2)
          }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 92)
      }
      .contentShape(Rectangle())
      .simultaneousGesture(
        TapGesture().onEnded {
          composerFocused = false
        }
      )
      .scrollDismissesKeyboard(.interactively)
      .onChange(of: chat.messages) { _, messages in
        scrollToBottom(proxy: proxy, messages: messages, animated: true)
      }
      .onChange(of: scrollToBottomRequestID) { _, _ in
        composerFocused = false
        scrollToBottom(proxy: proxy, messages: chat.messages, animated: true)
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      if GooseCoachPolicy.remoteExecutionEnabled {
        CoachComposer(
          draft: $draft,
          focused: $composerFocused,
          isStreaming: chat.streamState.isStreaming,
          send: sendDraft,
          cancel: {
            composerFocused = false
            chat.cancelStreaming()
          }
        )
      } else {
        CoachRemoteDisabledBar()
      }
    }
  }

  private func sendDraft() {
    let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !prompt.isEmpty else {
      return
    }
    draft = ""
    send(prompt: prompt)
  }

  private func send(prompt: String) {
    let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedPrompt.isEmpty else {
      return
    }
    chat.send(trimmedPrompt, healthStore: healthStore, appModel: appModel)
  }

  private func scrollToBottom(
    proxy: ScrollViewProxy,
    messages: [CoachChatMessage],
    animated: Bool
  ) {
    guard let lastID = messages.last?.id else {
      return
    }
    let action = {
      proxy.scrollTo(lastID, anchor: .bottom)
    }
    if animated {
      withAnimation(.easeOut(duration: 0.18)) {
        action()
      }
    } else {
      action()
    }
  }
}

private struct CoachRemoteDisabledNotice: View {
  let hasHistory: Bool
  let hasStoredCredentials: Bool
  let clearHistory: () -> Void
  let forgetCredentials: () -> Void
  @State private var confirmingClear = false
  @State private var confirmingForget = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(GooseCoachPolicy.disabledTitle, systemImage: "lock.shield")
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.orange)
      Text(GooseCoachPolicy.disabledSummary)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)

      if hasHistory || hasStoredCredentials {
        Divider()
          .padding(.vertical, 2)
      }

      if hasHistory {
        Text("Past Coach messages are still stored on this device.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button(role: .destructive) {
          confirmingClear = true
        } label: {
          Label("Clear Chat History", systemImage: "trash")
            .font(.footnote.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .accessibilityHint("Deletes the locally stored Coach conversation")
      }

      if hasStoredCredentials {
        Text("A Coach sign-in credential is still stored in the Keychain. It is never used while online Coach is disabled.")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
        Button(role: .destructive) {
          confirmingForget = true
        } label: {
          Label("Forget Coach Credentials", systemImage: "key.slash")
            .font(.footnote.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .accessibilityHint("Deletes the stored Coach sign-in credential from the Keychain")
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(Color.orange.opacity(0.30), lineWidth: 1)
    }
    .confirmationDialog(
      "Clear Coach chat history?",
      isPresented: $confirmingClear,
      titleVisibility: .visible
    ) {
      Button("Clear History", role: .destructive, action: clearHistory)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This deletes the locally stored Coach conversation on this device. It cannot be undone.")
    }
    .confirmationDialog(
      "Forget Coach credentials?",
      isPresented: $confirmingForget,
      titleVisibility: .visible
    ) {
      Button("Forget Credentials", role: .destructive, action: forgetCredentials)
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This deletes the stored Coach sign-in from this device's Keychain. No network request is made.")
    }
  }
}

private struct CoachRemoteDisabledBar: View {
  var body: some View {
    Label("Online Coach is disabled for privacy", systemImage: "wifi.slash")
      .font(.footnote.weight(.semibold))
      .foregroundStyle(.secondary)
      .frame(maxWidth: .infinity)
      .padding(.horizontal, 12)
      .padding(.vertical, 12)
      .background(.regularMaterial)
      .overlay(alignment: .top) {
        Divider()
          .opacity(0.6)
      }
  }
}

private struct CoachConnectionStrip: View {
  let streamState: CoachStreamState

  var body: some View {
    HStack(spacing: 8) {
      Image(systemName: streamState.isStreaming ? "dot.radiowaves.left.and.right" : "checkmark.seal.fill")
        .font(.caption.weight(.bold))
        .foregroundStyle(streamState.isStreaming ? .blue : .green)

      Text("Coach")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)

      Spacer()

      Text(statusText)
        .font(.caption2.weight(.bold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: Capsule(style: .continuous))
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 10)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
  }

  private var statusText: String {
    switch streamState {
    case .idle:
      return "Ready"
    case .streaming:
      return "Streaming"
    case .failed:
      return "Needs attention"
    }
  }
}

private struct CoachPromptSuggestion: Identifiable, Equatable {
  let id: String
  let title: String
  let detail: String
  let prompt: String
  let systemImage: String
}

private struct CoachSuggestionStack: View {
  let suggestions: [CoachPromptSuggestion]
  let send: (CoachPromptSuggestion) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Start Here")
        .font(.caption.weight(.bold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)

      ForEach(suggestions) { suggestion in
        CoachSuggestionButton(suggestion: suggestion) {
          send(suggestion)
        }
      }
    }
    .padding(.top, 2)
  }
}

private struct CoachSuggestionButton: View {
  let suggestion: CoachPromptSuggestion
  let send: () -> Void

  var body: some View {
    Button(action: send) {
      HStack(spacing: 12) {
        Image(systemName: suggestion.systemImage)
          .font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.blue)
          .frame(width: 34, height: 34)
          .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))

        VStack(alignment: .leading, spacing: 3) {
          Text(suggestion.title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
          Text(suggestion.detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
        }

        Spacer(minLength: 8)

        Image(systemName: "arrow.up.forward")
          .font(.caption.weight(.bold))
          .foregroundStyle(.tertiary)
      }
      .padding(12)
      .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
      .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .stroke(Color(.separator).opacity(0.22), lineWidth: 1)
      }
    }
    .buttonStyle(.plain)
  }
}
