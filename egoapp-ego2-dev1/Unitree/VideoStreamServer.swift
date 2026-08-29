//
//  VideoStreamServer.swift
//  Unitree
//
//  WebSocket server for H.264 video streaming
//

import Foundation
import AVFoundation
import Network
import UIKit
import VideoToolbox
import CommonCrypto

class VideoStreamServer: NSObject, ObservableObject {
    @Published var isServerRunning = false
    @Published var serverURL: String = "Not Started"
    @Published var connectedClients = 0

    private var listener: NWListener?
    private var connections: [WebSocketConnection] = []
    private let queue = DispatchQueue(label: "video.stream.server.queue")
    private let port: UInt16 = 5000

    private var currentFrame: Data?
    private let frameLock = NSLock()

    // H.264 encoder
    private var compressionSession: VTCompressionSession?
    private let encoderQueue = DispatchQueue(label: "video.encoder.queue")
    private let encoderStateLock = NSLock()
    private var isEncoderConfigured = false
    private var isEncodingFrame = false
    private var currentEncoderWidth: Int = 0
    private var currentEncoderHeight: Int = 0

    // Control flags
    private var isRunning = false
    private var frameCount: UInt64 = 0
    private var lastKeyFrameTime: Date = Date()

    // WebSocket connection wrapper
    private class WebSocketConnection {
        let connection: NWConnection
        var timer: DispatchSourceTimer?
        var isWebSocketReady = false
        var isSendingFrame = false
        weak var server: VideoStreamServer?

        init(connection: NWConnection, server: VideoStreamServer) {
            self.connection = connection
            self.server = server
        }

        func invalidate() {
            timer?.cancel()
            timer = nil
        }
    }

    override init() {
        super.init()
        print("🎥 VideoStreamServer initialized (not started yet)")
    }

    deinit {
        stopServerImmediate()
    }

    private func calculateBitrate(width: Int, height: Int) -> Int {
        let basePixels = 1280 * 720
        let actualPixels = width * height
        let baseBitrate = 2_000_000
        let bitrate = Int(Double(baseBitrate) * (Double(actualPixels) / Double(basePixels)))
        return max(bitrate, 1_000_000)
    }

    private func tryBeginEncodingFrame() -> Bool {
        encoderStateLock.lock()
        defer { encoderStateLock.unlock() }

        guard !isEncodingFrame else { return false }
        isEncodingFrame = true
        return true
    }

    private func setEncodingFrame(_ value: Bool) {
        encoderStateLock.lock()
        isEncodingFrame = value
        encoderStateLock.unlock()
    }

    func startServer() {
        guard !isRunning else {
            print("🎥 Server already running")
            return
        }

        isRunning = true
        frameCount = 0

        print("🎥 ========== Starting Video WebSocket Server ==========")
        print("🎥 Port: \(port)")

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true

            listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))
            print("🎥 Listener created successfully")

            listener?.stateUpdateHandler = { [weak self] state in
                guard let self = self, self.isRunning else { return }

                DispatchQueue.main.async {
                    print("🎥 Listener state changed to: \(state)")
                    switch state {
                    case .ready:
                        print("🎥 ✅ Video WebSocket server is READY on port \(self.port)")
                        self.isServerRunning = true
                        self.updateServerURL()
                    case .failed(let error):
                        print("🎥 ❌ Server failed: \(error)")
                        self.isServerRunning = false
                        self.serverURL = "Failed to Start"
                    case .cancelled:
                        print("🎥 Server cancelled")
                        self.isServerRunning = false
                        self.serverURL = "Not Started"
                    case .waiting(let error):
                        print("🎥 ⚠️ Server waiting: \(error)")
                    default:
                        break
                    }
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                guard let self = self, self.isRunning else {
                    connection.cancel()
                    return
                }
                print("🎥 📥 New WebSocket connection received!")
                self.handleNewConnection(connection)
            }

            listener?.start(queue: queue)
            print("🎥 Listener.start() called on queue")

        } catch {
            print("🎥 ❌ Failed to create server: \(error)")
            isRunning = false
            DispatchQueue.main.async {
                self.serverURL = "Creation Failed"
            }
        }
    }

    func stopServer() {
        print("🎥 stopServer() called")
        stopServerImmediate()
    }

    private func stopServerImmediate() {
        isRunning = false

        // Cancel listener first
        listener?.cancel()
        listener = nil

        // Cancel all connections
        queue.async { [weak self] in
            guard let self = self else { return }

            for wsConn in self.connections {
                wsConn.invalidate()
                wsConn.connection.cancel()
            }
            self.connections.removeAll()

            DispatchQueue.main.async {
                self.connectedClients = 0
            }
        }

        // Invalidate encoder on encoder queue
        encoderQueue.async { [weak self] in
            if let session = self?.compressionSession {
                VTCompressionSessionInvalidate(session)
                self?.compressionSession = nil
                self?.isEncoderConfigured = false
            }
            self?.setEncodingFrame(false)
        }

        // Clear current frame
        frameLock.lock()
        currentFrame = nil
        frameLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.isServerRunning = false
            self?.serverURL = "Not Started"
        }

        print("🎥 ✅ Server stopped")
    }

    private func handleNewConnection(_ connection: NWConnection) {
        let wsConn = WebSocketConnection(connection: connection, server: self)

        connection.stateUpdateHandler = { [weak self, weak wsConn] state in
            guard let self = self, let wsConn = wsConn, self.isRunning else { return }

            switch state {
            case .ready:
                self.connections.append(wsConn)
                let count = self.connections.count
                DispatchQueue.main.async {
                    self.connectedClients = count
                }
                self.handleWebSocketHandshake(wsConn)
            case .cancelled, .failed:
                self.removeConnection(wsConn)
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    private func handleWebSocketHandshake(_ wsConn: WebSocketConnection) {
        guard isRunning else { return }

        wsConn.connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak wsConn] data, _, _, error in
            guard let self = self, let wsConn = wsConn, self.isRunning else { return }
            guard let data = data, !data.isEmpty else { return }

            if let requestString = String(data: data, encoding: .utf8) {
                print("🎥 Received HTTP request for WebSocket upgrade")

                // Parse WebSocket key
                if let key = self.extractWebSocketKey(from: requestString) {
                    let acceptKey = self.generateWebSocketAcceptKey(from: key)

                    let response = """
                    HTTP/1.1 101 Switching Protocols\r
                    Upgrade: websocket\r
                    Connection: Upgrade\r
                    Sec-WebSocket-Accept: \(acceptKey)\r
                    \r

                    """.data(using: .utf8)!

                    wsConn.connection.send(content: response, completion: .contentProcessed({ [weak self, weak wsConn] error in
                        guard let self = self, let wsConn = wsConn, self.isRunning else { return }

                        if error == nil {
                            print("🎥 ✅ WebSocket handshake completed")
                            wsConn.isWebSocketReady = true
                            self.startStreamingToConnection(wsConn)
                        } else {
                            print("🎥 ❌ Failed to send WebSocket response: \(String(describing: error))")
                        }
                    }))
                } else {
                    print("🎥 ⚠️ Not a WebSocket request, closing connection")
                    wsConn.connection.cancel()
                }
            }
        }
    }

    private func extractWebSocketKey(from request: String) -> String? {
        let lines = request.components(separatedBy: "\r\n")
        for line in lines {
            if line.lowercased().hasPrefix("sec-websocket-key:") {
                let parts = line.components(separatedBy: ":")
                if parts.count >= 2 {
                    return parts[1...].joined(separator: ":").trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }

    private func generateWebSocketAcceptKey(from key: String) -> String {
        let magicString = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let combined = key + magicString

        // SHA1 hash
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        let data = combined.data(using: .utf8)!
        data.withUnsafeBytes { bytes in
            _ = CC_SHA1(bytes.baseAddress, CC_LONG(data.count), &digest)
        }

        // Base64 encode
        return Data(digest).base64EncodedString()
    }

    private func createWebSocketFrame(data: Data, opcode: UInt8 = 0x02) -> Data {
        var frame = Data()

        // FIN + opcode (0x02 = binary)
        frame.append(0x80 | opcode)

        // Payload length (server doesn't mask)
        if data.count < 126 {
            frame.append(UInt8(data.count))
        } else if data.count < 65536 {
            frame.append(126)
            frame.append(UInt8((data.count >> 8) & 0xFF))
            frame.append(UInt8(data.count & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() {
                frame.append(UInt8((data.count >> (i * 8)) & 0xFF))
            }
        }

        // Payload
        frame.append(data)

        return frame
    }

    private func startStreamingToConnection(_ wsConn: WebSocketConnection) {
        guard isRunning else { return }

        print("🎥 Starting WebSocket video stream")

        queue.async { [weak self, weak wsConn] in
            guard let self = self, let wsConn = wsConn, self.isRunning else { return }

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .nanoseconds(33_333_333))
            timer.setEventHandler { [weak self, weak wsConn] in
                guard let self = self, let wsConn = wsConn else { return }

                // Check if we should stop
                guard self.isRunning else {
                    wsConn.invalidate()
                    return
                }

                guard wsConn.connection.state == .ready && wsConn.isWebSocketReady else {
                    wsConn.invalidate()
                    self.removeConnectionOnQueue(wsConn)
                    return
                }

                // Drop frames while a previous network send is still in flight.
                guard !wsConn.isSendingFrame else {
                    return
                }

                // Get frame data with lock (fast operation)
                self.frameLock.lock()
                let frameData = self.currentFrame
                self.frameLock.unlock()

                guard let frameData = frameData else { return }

                // Send H.264 frame as WebSocket binary message
                let wsFrame = self.createWebSocketFrame(data: frameData)
                wsConn.isSendingFrame = true

                wsConn.connection.send(content: wsFrame, completion: .contentProcessed({ [weak self, weak wsConn] error in
                    guard let self = self, let wsConn = wsConn else { return }
                    self.queue.async {
                        wsConn.isSendingFrame = false

                        if let error = error {
                            print("🎥 ❌ Failed to send video frame: \(error)")
                            wsConn.invalidate()
                            self.removeConnectionOnQueue(wsConn)
                        }
                    }
                }))
            }

            wsConn.timer = timer
            timer.resume()
        }
    }

    private func removeConnection(_ wsConn: WebSocketConnection) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.removeConnectionOnQueue(wsConn)
        }
    }

    private func removeConnectionOnQueue(_ wsConn: WebSocketConnection) {
        if let index = connections.firstIndex(where: { $0.connection === wsConn.connection }) {
            connections[index].invalidate()
            connections.remove(at: index)
            let count = connections.count
            DispatchQueue.main.async {
                self.connectedClients = count
            }
        }
    }

    private func updateServerURL() {
        if let ip = getWiFiAddress() {
            print("✅ Successfully obtained IP address: \(ip)")
            DispatchQueue.main.async {
                self.serverURL = "ws://\(ip):\(self.port)"
            }
        } else {
            print("❌ Unable to obtain IP address")
            DispatchQueue.main.async {
                self.serverURL = "Unable to get IP"
            }
        }
    }

    private func getWiFiAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0 else { return nil }
        guard let firstAddr = ifaddr else { return nil }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee

            guard (flags & (IFF_UP|IFF_RUNNING|IFF_LOOPBACK)) == (IFF_UP|IFF_RUNNING) else {
                continue
            }

            if addr.sa_family == UInt8(AF_INET) {
                let name = String(cString: ptr.pointee.ifa_name)

                if name == "en0" || name == "en1" || name.hasPrefix("en") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                    let ipAddress = String(cString: hostname)

                    if !ipAddress.hasPrefix("127.") && !ipAddress.isEmpty {
                        address = ipAddress
                        if name == "en0" { break }
                    }
                }
            }
        }

        freeifaddrs(ifaddr)
        return address
    }
}

// MARK: - H.264 Encoding
extension VideoStreamServer {
    private func configureEncoderIfNeeded(width: Int, height: Int) {
        guard !isEncoderConfigured else { return }
        guard isRunning else { return }

        print("🎥 Configuring H.264 encoder: \(width)x\(height)")

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: { (outputCallbackRefCon, sourceFrameRefCon, status, infoFlags, sampleBuffer) in
                guard let sampleBuffer = sampleBuffer else { return }
                let server = Unmanaged<VideoStreamServer>.fromOpaque(outputCallbackRefCon!).takeUnretainedValue()
                server.handleEncodedFrame(sampleBuffer)
            },
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &session
        )

        guard status == noErr, let session = session else {
            print("❌ Failed to create compression session: \(status)")
            return
        }

        let bitrate = calculateBitrate(width: width, height: height)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 60 as CFNumber)  // Key frame every 2 seconds at 30fps
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: 30 as CFNumber)

        VTCompressionSessionPrepareToEncodeFrames(session)

        self.compressionSession = session
        self.isEncoderConfigured = true
        self.currentEncoderWidth = width
        self.currentEncoderHeight = height
        self.lastKeyFrameTime = Date()
        print("✅ H.264 encoder configured: \(width)x\(height), bitrate: \(bitrate)")
    }

    private func handleEncodedFrame(_ sampleBuffer: CMSampleBuffer) {
        guard isRunning else {
            if Int.random(in: 0..<30) == 0 {
                print("🎥 ⚠️ Encoded frame dropped: server not running")
            }
            return
        }
        guard CMSampleBufferDataIsReady(sampleBuffer) else {
            print("🎥 ⚠️ Sample buffer not ready")
            return
        }

        var data = Data()

        // Get SPS/PPS from format description - send periodically for robustness
        let shouldSendSPSPPS = frameCount % 60 == 0  // Every 2 seconds at 30fps

        if shouldSendSPSPPS, let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
            var parameterSetCount = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription, parameterSetIndex: 0,
                                                               parameterSetPointerOut: nil,
                                                               parameterSetSizeOut: nil,
                                                               parameterSetCountOut: &parameterSetCount,
                                                               nalUnitHeaderLengthOut: nil)

            if parameterSetCount > 0 {
                for i in 0..<parameterSetCount {
                    var parameterSetPointer: UnsafePointer<UInt8>?
                    var parameterSetSize = 0
                    CMVideoFormatDescriptionGetH264ParameterSetAtIndex(formatDescription,
                                                                       parameterSetIndex: i,
                                                                       parameterSetPointerOut: &parameterSetPointer,
                                                                       parameterSetSizeOut: &parameterSetSize,
                                                                       parameterSetCountOut: nil,
                                                                       nalUnitHeaderLengthOut: nil)
                    if let parameterSetPointer = parameterSetPointer, parameterSetSize > 0 {
                        data.append(contentsOf: [0, 0, 0, 1])
                        data.append(parameterSetPointer, count: parameterSetSize)
                    }
                }
            }
        }

        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)

        guard let dataPointer = dataPointer, length > 0 else { return }

        let uint8Pointer = UnsafeMutableRawPointer(dataPointer).assumingMemoryBound(to: UInt8.self)

        // Convert AVCC to Annex B
        var offset = 0
        while offset < length - 4 {
            let nalLength = Int(uint8Pointer[offset]) << 24 |
                          Int(uint8Pointer[offset + 1]) << 16 |
                          Int(uint8Pointer[offset + 2]) << 8 |
                          Int(uint8Pointer[offset + 3])

            guard nalLength > 0 && nalLength < length else { break }

            let nalStart = offset + 4
            guard nalStart + nalLength <= length else { break }

            data.append(contentsOf: [0, 0, 0, 1])
            let nalBytes = UnsafeBufferPointer(start: uint8Pointer.advanced(by: nalStart), count: nalLength)
            data.append(contentsOf: nalBytes)

            offset = nalStart + nalLength
        }

        // Update current frame atomically
        frameLock.lock()
        self.currentFrame = data
        frameLock.unlock()

        frameCount += 1

        // Log every 30 frames (about 1 second at 30fps) for debugging
        if frameCount % 30 == 0 {
            print("🎥 Encoded H.264 frame #\(frameCount): \(data.count) bytes, clients: \(connectedClients)")
        }
    }

}

// MARK: - VideoStreamDelegate
extension VideoStreamServer: VideoStreamDelegate {
    func didCaptureVideoFrame(_ sampleBuffer: CMSampleBuffer, depthData: AVDepthData?) {
        // Nothing in the dataset pipeline consumes this stream -- it reaches
        // the bag through rosbridge, not through port 5000 -- so in practice
        // no one ever connects. dataset_session_20260829_130658 was recorded
        // with "clients: 0" on every encode line for four minutes, H.264ing
        // 1920x1440 for an empty room. That is CPU and battery spent competing
        // with the websocket sends that were timing out.
        guard connectedClients > 0 else { return }
        guard isRunning else {
            // Log occasionally when frames are being dropped because we're not running
            if Int.random(in: 0..<100) == 0 {
                print("🎥 ⚠️ Frame dropped: server not running")
            }
            return
        }

        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("🎥 ⚠️ Frame dropped: no image buffer")
            return
        }

        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)

        // Log receiving frames
        if frameCount == 0 || frameCount % 30 == 0 {
            print("🎥 📥 Received frame: \(width)x\(height), total: \(frameCount), encoder: \(isEncoderConfigured), session: \(compressionSession != nil)")
        }

        guard tryBeginEncodingFrame() else { return }

        encoderQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.setEncodingFrame(false) }
            guard self.isRunning else { return }

            self.configureEncoderIfNeeded(width: width, height: height)

            guard let session = self.compressionSession else {
                if self.frameCount % 30 == 0 {
                    print("🎥 ⚠️ No compression session available")
                }
                return
            }

            let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let duration = CMSampleBufferGetDuration(sampleBuffer)

            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: imageBuffer,
                presentationTimeStamp: presentationTimeStamp,
                duration: duration,
                frameProperties: nil,
                sourceFrameRefcon: nil,
                infoFlagsOut: nil
            )

            if status != noErr {
                print("⚠️ Encode frame error: \(status)")
            }
        }
    }

    func videoOrientationDidChange() {
        print("ℹ️ Video orientation change ignored")
    }
}
