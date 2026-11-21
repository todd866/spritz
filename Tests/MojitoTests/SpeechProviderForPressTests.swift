import Testing
@testable import Mojito

struct SpeechProviderForPressTests {
    @Test func chatGPTModesFallBackToAppleWhenChatGPTIsClosed() {
        #expect(SpeechInputProvider.forPress(.chatgpt, chatGPTRunning: false) == .apple)
        #expect(SpeechInputProvider.forPress(.layered, chatGPTRunning: false) == .apple)
    }
    @Test func preferredProviderKeptWhenChatGPTIsRunning() {
        #expect(SpeechInputProvider.forPress(.chatgpt, chatGPTRunning: true) == .chatgpt)
        #expect(SpeechInputProvider.forPress(.layered, chatGPTRunning: true) == .layered)
        #expect(SpeechInputProvider.forPress(.apple, chatGPTRunning: false) == .apple)
    }
}
