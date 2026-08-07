import XCTest

final class RecordingRecoveryTests: XCTestCase {
    func test_audioCaptureFailureOffersRetryAndInputSettings() {
        let notice = RecordingRecoveryNotice.forKind(.audioInputUnavailable)

        XCTAssertEqual(notice.title, "麦克风暂时无法使用")
        XCTAssertEqual(notice.primaryAction, .retry)
        XCTAssertEqual(notice.secondaryAction, .openInputSettings)
        XCTAssertTrue(notice.message.contains("已检测到麦克风"))
        XCTAssertTrue(notice.message.contains("无法开始采集声音"))
        XCTAssertTrue(notice.message.contains("重新连接耳机"))
        XCTAssertFalse(notice.message.contains("音频格式"))
    }

    func test_missingMicrophoneExplainsThatAnInputDeviceIsRequired() {
        let notice = RecordingRecoveryNotice.forKind(.noInputDevice)

        XCTAssertEqual(notice.primaryAction, .retry)
        XCTAssertEqual(notice.secondaryAction, .openInputSettings)
        XCTAssertTrue(notice.message.contains("麦克风"))
    }

    func test_microphonePermissionOffersMicrophoneSettings() {
        let notice = RecordingRecoveryNotice.forKind(.microphonePermission)

        XCTAssertEqual(notice.primaryAction, .openMicrophoneSettings)
        XCTAssertNil(notice.secondaryAction)
    }

    func test_serviceFailureDoesNotPretendToBeAnAudioFailure() {
        let notice = RecordingRecoveryNotice.forKind(.serviceUnavailable)

        XCTAssertEqual(notice.primaryAction, .retry)
        XCTAssertNil(notice.secondaryAction)
        XCTAssertTrue(notice.message.contains("网络"))
        XCTAssertTrue(notice.message.contains("启动较慢"))
    }
}
