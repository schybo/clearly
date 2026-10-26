#if os(iOS)
import Foundation
import Observation

#if canImport(PlaudDeviceBasicSDK) && canImport(PlaudBleSDK)
import PlaudBleSDK
import PlaudDeviceBasicSDK
#endif

@MainActor
@Observable
final class PlaudDeviceImportService {
    enum State: Equatable {
        case idle
        case fetchingToken
        case scanning
        case connecting(PlaudDiscoveredDevice)
        case connected
        case loadingFiles
        case exporting(PlaudRecordingFile)
        case transcribing(PlaudRecordingFile)
        case imported
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var devices: [PlaudDiscoveredDevice] = []
    private(set) var recordings: [PlaudRecordingFile] = []
    private(set) var activeToken: PlaudAccessToken?
    var region: PlaudRegion = .us

    @ObservationIgnored private let tokenService: PlaudTokenService
    @ObservationIgnored private let transcriptionService: PlaudTranscriptionService
    @ObservationIgnored private var bridge: PlaudDeviceControlling

    var isSDKAvailable: Bool {
        bridge.isAvailable
    }

    init(
        tokenService: PlaudTokenService = PlaudTokenService(),
        transcriptionService: PlaudTranscriptionService = PlaudTranscriptionService(),
        bridge: PlaudDeviceControlling = PlaudDeviceBridgeFactory.make()
    ) {
        self.tokenService = tokenService
        self.transcriptionService = transcriptionService
        self.bridge = bridge
        self.bridge.onDevices = { [weak self] devices in
            self?.devices = devices
        }
        self.bridge.onFiles = { [weak self] files in
            self?.recordings = files
            self?.state = .connected
        }
        self.bridge.onConnectionState = { [weak self] isConnected in
            self?.state = isConnected ? .connected : .idle
        }
        self.bridge.onFailure = { [weak self] message in
            self?.state = .failed(message)
        }
    }

    func prepare(authService: WiskAuthService) async {
        state = .fetchingToken
        do {
            let token = try await tokenService.accessToken(authService: authService, region: region)
            activeToken = token
            try bridge.configure(accessToken: token.accessToken, host: token.regionHost)
            state = .idle
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func startScan() {
        do {
            devices = []
            state = .scanning
            try bridge.startScan()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func connect(to device: PlaudDiscoveredDevice) {
        do {
            state = .connecting(device)
            try bridge.connect(to: device)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func refreshFileList() {
        do {
            state = .loadingFiles
            try bridge.requestFileList()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func transcribe(recording: PlaudRecordingFile, authService: WiskAuthService) async throws -> PlaudTranscript {
        guard let token = activeToken else {
            throw PlaudDeviceImportError.missingToken
        }

        state = .exporting(recording)
        let audioURL = try await bridge.exportAudio(recording)
        let firebaseToken = try await authService.idToken(forceRefresh: false)
        state = .transcribing(recording)
        let transcript = try await transcriptionService.transcribe(
            audioURL: audioURL,
            plaudToken: token,
            firebaseIDToken: firebaseToken
        )
        state = .imported
        return transcript
    }

    func deleteRecording(_ recording: PlaudRecordingFile) {
        do {
            try bridge.deleteRecording(recording)
            recordings.removeAll { $0.sessionId == recording.sessionId }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}

@MainActor
protocol PlaudDeviceControlling: AnyObject {
    var isAvailable: Bool { get }
    var onDevices: (([PlaudDiscoveredDevice]) -> Void)? { get set }
    var onFiles: (([PlaudRecordingFile]) -> Void)? { get set }
    var onConnectionState: ((Bool) -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }

    func configure(accessToken: String, host: String) throws
    func startScan() throws
    func connect(to device: PlaudDiscoveredDevice) throws
    func requestFileList() throws
    func exportAudio(_ recording: PlaudRecordingFile) async throws -> URL
    func deleteRecording(_ recording: PlaudRecordingFile) throws
}

enum PlaudDeviceBridgeFactory {
    @MainActor
    static func make() -> PlaudDeviceControlling {
        #if canImport(PlaudDeviceBasicSDK) && canImport(PlaudBleSDK)
        PlaudSDKDeviceBridge()
        #else
        PlaudUnavailableDeviceBridge()
        #endif
    }
}

private enum PlaudDeviceImportError: LocalizedError {
    case missingToken
    case sdkUnavailable
    case deviceNotFound
    case exportAlreadyRunning
    case exportFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingToken:
            "Fetch a Plaud access token before importing recordings."
        case .sdkUnavailable:
            "Plaud SDK frameworks are not linked. Add the Plaud SDK package/frameworks and build on a physical device."
        case .deviceNotFound:
            "The selected Plaud device was not found in the latest scan results."
        case .exportAlreadyRunning:
            "A Plaud audio export is already running."
        case .exportFailed(let message):
            "Plaud audio export failed: \(message)"
        }
    }
}

private final class PlaudUnavailableDeviceBridge: PlaudDeviceControlling {
    var isAvailable: Bool { false }
    var onDevices: (([PlaudDiscoveredDevice]) -> Void)?
    var onFiles: (([PlaudRecordingFile]) -> Void)?
    var onConnectionState: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?

    func configure(accessToken: String, host: String) throws {
        throw PlaudDeviceImportError.sdkUnavailable
    }

    func startScan() throws {
        throw PlaudDeviceImportError.sdkUnavailable
    }

    func connect(to device: PlaudDiscoveredDevice) throws {
        throw PlaudDeviceImportError.sdkUnavailable
    }

    func requestFileList() throws {
        throw PlaudDeviceImportError.sdkUnavailable
    }

    func exportAudio(_ recording: PlaudRecordingFile) async throws -> URL {
        throw PlaudDeviceImportError.sdkUnavailable
    }

    func deleteRecording(_ recording: PlaudRecordingFile) throws {
        throw PlaudDeviceImportError.sdkUnavailable
    }
}

#if canImport(PlaudDeviceBasicSDK) && canImport(PlaudBleSDK)
private final class PlaudSDKDeviceBridge: NSObject, PlaudDeviceControlling {
    var isAvailable: Bool { true }
    var onDevices: (([PlaudDiscoveredDevice]) -> Void)?
    var onFiles: (([PlaudRecordingFile]) -> Void)?
    var onConnectionState: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?

    private var cachedDevices: [String: BleDevice] = [:]
    private var exportContinuation: CheckedContinuation<URL, Error>?

    func configure(accessToken: String, host: String) throws {
        PlaudDeviceAgent.shared.delegate = self
        PlaudDeviceAgent.shared.initSDK(userAccessToken: accessToken, customDomain: host)
    }

    func startScan() throws {
        cachedDevices.removeAll()
        PlaudDeviceAgent.shared.startScan()
    }

    func connect(to device: PlaudDiscoveredDevice) throws {
        guard let bleDevice = cachedDevices[device.serialNumber] else {
            throw PlaudDeviceImportError.deviceNotFound
        }
        PlaudDeviceAgent.shared.connectBleDevice(bleDevice: bleDevice, deviceToken: "wisk")
    }

    func requestFileList() throws {
        PlaudDeviceAgent.shared.getFileList(startSessionId: 0)
    }

    func exportAudio(_ recording: PlaudRecordingFile) async throws -> URL {
        guard exportContinuation == nil else {
            throw PlaudDeviceImportError.exportAlreadyRunning
        }
        let outputDir = try Self.outputDirectory().path
        return try await withCheckedThrowingContinuation { continuation in
            exportContinuation = continuation
            PlaudDeviceAgent.shared.exportAudio(
                sessionId: recording.sessionId,
                outputDir: outputDir,
                format: .opus,
                channels: 1,
                callback: self
            )
        }
    }

    func deleteRecording(_ recording: PlaudRecordingFile) throws {
        PlaudDeviceAgent.shared.deleteFile(sessionId: recording.sessionId)
    }

    private static func outputDirectory() throws -> URL {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PlaudImports", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}

extension PlaudSDKDeviceBridge: PlaudDeviceAgentProtocol {
    func bleScanResult(bleDevices: [BleDevice]) {
        cachedDevices = Dictionary(uniqueKeysWithValues: bleDevices.map { ($0.serialNumber, $0) })
        let devices = bleDevices.map {
            PlaudDiscoveredDevice(name: $0.name, serialNumber: $0.serialNumber, rssi: $0.rssi)
        }
        .sorted { $0.rssi > $1.rssi }
        DispatchQueue.main.async { [weak self] in
            self?.onDevices?(devices)
        }
    }

    func bleConnectState(state: Int) {
        DispatchQueue.main.async { [weak self] in
            switch state {
            case 1:
                self?.onConnectionState?(true)
            case 0:
                self?.onConnectionState?(false)
            case 2, -1, -2:
                self?.onFailure?("Plaud connection failed with code \(state).")
            default:
                break
            }
        }
    }

    func bleFileList(bleFiles: [BleFile]) {
        let files = bleFiles.map { file in
            PlaudRecordingFile(
                sessionId: file.sessionId,
                deviceSerialNumber: file.sn,
                sizeBytes: file.size,
                duration: TimeInterval(file.duration()) / 1000
            )
        }
        .sorted { $0.createdAt > $1.createdAt }
        DispatchQueue.main.async { [weak self] in
            self?.onFiles?(files)
        }
    }
}

extension PlaudSDKDeviceBridge: AudioExportCallback {
    func onProgress(_ progress: Int, message: String) {}

    func onComplete(outputPath: String) {
        let continuation = exportContinuation
        exportContinuation = nil
        continuation?.resume(returning: URL(fileURLWithPath: outputPath))
    }

    func onError(_ error: String) {
        let continuation = exportContinuation
        exportContinuation = nil
        continuation?.resume(throwing: PlaudDeviceImportError.exportFailed(error))
        onFailure?(error)
    }
}
#endif
#endif
