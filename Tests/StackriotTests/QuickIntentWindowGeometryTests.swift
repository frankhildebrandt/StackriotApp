import CoreGraphics
import Testing
@testable import Stackriot

struct QuickIntentWindowGeometryTests {
    @Test
    func centersIdealQuickIntentPopupOnLargeDisplays() {
        let visibleFrame = CGRect(x: 100, y: 80, width: 1720, height: 1117)

        let frame = QuickIntentWindowGeometry.frame(in: visibleFrame)

        #expect(abs(frame.width - QuickIntentWindowGeometry.idealSize.width) <= 1)
        #expect(abs(frame.height - QuickIntentWindowGeometry.idealSize.height) <= 1)
        #expect(abs(frame.midX - visibleFrame.midX) <= 0.5)
        #expect(abs(frame.midY - visibleFrame.midY) <= 0.5)
    }

    @Test
    func shrinksPopupToStayInsideSmallerDisplays() {
        let visibleFrame = CGRect(x: 0, y: 24, width: 700, height: 560)

        let frame = QuickIntentWindowGeometry.frame(in: visibleFrame)

        #expect(frame.width <= visibleFrame.width)
        #expect(frame.height <= visibleFrame.height)
        #expect(frame.minX >= visibleFrame.minX)
        #expect(frame.maxX <= visibleFrame.maxX)
        #expect(frame.minY >= visibleFrame.minY)
        #expect(frame.maxY <= visibleFrame.maxY)
        #expect(abs(frame.midX - visibleFrame.midX) <= 0.5)
        #expect(abs(frame.midY - visibleFrame.midY) <= 0.5)
    }
}
