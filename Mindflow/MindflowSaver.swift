//
//  MindflowSaver.swift
//  Mindflow — orchestrator. On hotkey press: start audio. On release: stop audio,
//  capture screen, transcribe, persist screenshot, hand off to ChatAgent with a
//  session ID + the persisted screenshot path so the agent can attach it to a
//  MemoryRecord when the session ends.
//

import Foundation

@MainActor
final class MindflowSaver {
    let audioRecorder: AudioRecorder
    let screenCapturer: ScreenCapturer
    let deepgram: DeepgramClient
    let notifier: Notifier
    let popup: PopupController
    let chatAgent: ChatAgent
    let screenshotStore: ScreenshotStore

    private var isCapturing = false

    init(
        deepgramApiKey: String,
        anthropicApiKey: String,
        notifier: Notifier,
        popup: PopupController,
        chatAgent: ChatAgent,
        screenshotStore: ScreenshotStore
    ) {
        self.audioRecorder = AudioRecorder()
        self.screenCapturer = ScreenCapturer()
        self.deepgram = DeepgramClient(apiKey: deepgramApiKey)
        self.notifier = notifier
        self.popup = popup
        self.chatAgent = chatAgent
        self.screenshotStore = screenshotStore
    }

    /// Push-to-talk for every turn — press starts recording, release sends.
    /// Mirrors what users expect from a Slack/Discord push-to-talk and avoids
    /// the "did I forget to untoggle?" confusion.
    func handleHotkeyPress() {
        startCapture()
    }

    func handleHotkeyRelease() {
        finishCapture()
    }

    /// Hotkey press handler — starts recording audio.
    func startCapture() {
        guard !isCapturing else { return }
        isCapturing = true
        // Drives the chat-header listening indicator while the mic is hot.
        chatAgent.isRecording = true
        print("[Mindflow] === hotkey PRESS ===")

        popup.state.reset()
        popup.state.phase = .listening
        popup.show()

        Task { [audioRecorder, notifier, popup] in
            do {
                try await audioRecorder.start()
            } catch {
                print("[Mindflow] start failed: \(error)")
                popup.state.phase = .failed(message: "mic permission")
                await notifier.notify("Couldn't start recording: \(error)")
            }
        }
    }

    /// Hotkey release handler — stops recording, transcribes, hands context to the chat agent.
    func finishCapture() {
        guard isCapturing else { return }
        isCapturing = false
        chatAgent.isRecording = false
        print("[Mindflow] === hotkey RELEASE ===")

        popup.state.phase = .processing(stage: "transcribing…")

        Task { [audioRecorder, screenCapturer, deepgram, notifier, popup, chatAgent, screenshotStore] in
            do {
                print("[Mindflow] step 1/4: stopping audio")
                let wavURL = try await audioRecorder.stop()

                print("[Mindflow] step 2/4: capturing screen")
                popup.state.phase = .processing(stage: "reading screen…")
                let screenshot = try await screenCapturer.captureFrontmostWindow()
                print("[Mindflow]   screenshot: \(screenshot.count) bytes")

                print("[Mindflow] step 3/4: transcribing")
                popup.state.phase = .processing(stage: "transcribing…")
                let transcript = try await deepgram.transcribe(wavFile: wavURL)
                print("[Mindflow]   transcript: \"\(transcript)\"")
                popup.state.transcript = transcript

                print("[Mindflow] step 4/4: persist screenshot + hand off to ChatAgent")
                let screenshotID = UUID()
                let screenshotURL = try screenshotStore.save(screenshot, forID: screenshotID)
                let (appName, url) = AppContextProbe.current()
                print("[Mindflow]   screenshot=\(screenshotID), app=\(appName), url=\(url ?? "none")")
                popup.state.phase = .processing(stage: "thinking…")

                if chatAgent.messages.isEmpty {
                    // Fresh session — grow the popup to chat dimensions before the
                    // agent populates messages.
                    print("[Mindflow]   starting fresh chat session")
                    popup.resizeForChat()
                    print("[Mindflow]   resizeForChat done, awaiting startWithContext")
                    await chatAgent.startWithContext(
                        sessionID: screenshotID,
                        screenshotPath: screenshotURL.path,
                        initialTranscript: transcript,
                        appName: appName,
                        url: url
                    )
                } else {
                    // Chat is still open from a previous hold — append another turn.
                    // Don't resize: preserves any manual resize the user has done.
                    print("[Mindflow]   chat already open, appending turn (messages.count=\(chatAgent.messages.count))")
                    await chatAgent.appendContextTurn(
                        screenshotPath: screenshotURL.path,
                        transcript: transcript,
                        appName: appName,
                        url: url
                    )
                }
                print("[Mindflow]   handoff complete: messages.count=\(chatAgent.messages.count)")

                try? FileManager.default.removeItem(at: wavURL)
                print("[Mindflow] === HANDED OFF TO CHAT ===")
            } catch {
                print("[Mindflow] CAPTURE ERROR: \(error)")
                popup.state.phase = .failed(message: "\(error)")
                await notifier.notify("Capture failed: \(error)")
            }
        }
    }
}
