@testable import Stackriot
import Testing

struct LogPreviewTextTests {
    @Test
    func tailReturnsLastThreeEffectiveLines() {
        let text = """
        line 1
        line 2
        line 3
        line 4
        line 5
        """

        #expect(LogPreviewText.tail(from: text, lineCount: 3) == "line 3\nline 4\nline 5")
        #expect(LogPreviewText.lineCount(for: text) == 5)
    }

    @Test
    func tailIgnoresTrailingBlankLines() {
        let text = "line 1\nline 2\nline 3\n"

        #expect(LogPreviewText.tail(from: text, lineCount: 3) == "line 1\nline 2\nline 3")
        #expect(LogPreviewText.lineCount(for: text) == 3)
    }
}
