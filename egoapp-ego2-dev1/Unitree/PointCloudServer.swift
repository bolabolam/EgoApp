//
//  PointCloudServer.swift
//  Unitree
//
//  ROS2 Bridge WebSocket Client for publishing PointCloud2 data
//

import Foundation
import AVFoundation
import Network
import ARKit
import CommonCrypto

enum RosBridgeDefaults {
    /// Address of the machine running rosbridge. The phone's personal hotspot
    /// hands out 172.20.10.x by DHCP (the phone itself is .1), so the host
    /// moves between .2/.3/.4 as it reconnects — set a static lease on the
    /// host to stop it drifting, or type the address into the app's IP panel.
    static let currentHost = "172.20.10.3"

    private static let savedHostKey = "rosBridgeHost"
    private static let userSetKey = "rosBridgeHostWasSetByUser"

    /// A host the user typed into the IP panel wins permanently. Otherwise we
    /// follow `currentHost`, so bumping that constant still migrates phones
    /// that never had one entered by hand.
    ///
    /// The previous version kept a `legacyDefaultHosts` blocklist and rewrote
    /// any saved host that appeared in it. That silently reverted addresses
    /// the user had entered on purpose — once the host machine landed back on
    /// a blocklisted address, it could not be configured from the app at all.
    static func savedOrCurrentHost() -> String {
        guard UserDefaults.standard.bool(forKey: userSetKey),
              let savedHost = UserDefaults.standard.string(forKey: savedHostKey) else {
            UserDefaults.standard.set(currentHost, forKey: savedHostKey)
            return currentHost
        }

        let normalizedHost = savedHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedHost.isEmpty else {
            UserDefaults.standard.set(currentHost, forKey: savedHostKey)
            return currentHost
        }

        return normalizedHost
    }

    /// Records a host the user chose explicitly, so it survives future changes
    /// to `currentHost`.
    static func saveUserHost(_ host: String) {
        UserDefaults.standard.set(host, forKey: savedHostKey)
        UserDefaults.standard.set(true, forKey: userSetKey)
    }
}

class PointCloudServer: NSObject, ObservableObject {
    @Published var isServerRunning = false
    @Published var serverURL: String = "Not Connected"
    @Published var connectedClients = 0  // Reused as connection status indicator

    // ROS2 Bridge configuration - IP is configurable, port is fixed at 9090
    @Published var rosBridgeHost: String {
        didSet {
            // Only reached when the IP panel saves; the initial value comes
            // from init, where property observers do not fire.
            RosBridgeDefaults.saveUserHost(rosBridgeHost)
            print("☁️ ROS2 Bridge IP updated to: \(rosBridgeHost)")
        }
    }
    private let rosBridgePort: UInt16 = 9090
    private let topicName = "/camera_person/points"

    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var isConnected = false
    private var reconnectTimer: Timer?

    // Store pre-built publish JSON string, ready to send directly
    private var currentPublishMessage: String?
    private let pointCloudQueue = DispatchQueue(label: "pointcloud.data.queue")

    // Sequence counter for ROS2 messages
    private var sequenceCounter: UInt32 = 0

    // Publishing timer
    private var publishTimer: Timer?
    private let publishRate: Double = 5.0  // 5 Hz (reduced from 10 Hz for stability)

    // Backpressure: skip publish if previous send is still in flight
    private let sendStateLock = NSLock()
    private var isSending = false

    // Backpressure: skip depth frames while point extraction is still running.
    private let depthProcessingLock = NSLock()
    private var isProcessingDepth = false

    // Control flag to prevent reconnection after explicit stop
    private var isRunning = false
    private var frameCount: UInt64 = 0

    // Reusable buffer for binary point data to avoid repeated allocations
    private var binaryBuffer = Data()

    // Downsample step: higher = fewer points = faster transmission
    // LiDAR depth is typically 256x192, step=2 gives ~6K points, step=4 gives ~1.5K
    private let sampleStep = 2

    /// Intrinsics from the hardware, scaled to the depth map, once
    /// CameraManager has them. Nil until the first sample buffer arrives.
    ///
    /// The fallbacks below stood in for these and were wrong in the way that
    /// is easy to miss: fx = width * 0.9 and fy = height * 0.9 make fx/fy the
    /// image's 4:3 aspect ratio, which is the pixel aspect ratio only if the
    /// pixels are 4:3, and they are square. Measured on this phone the depth
    /// map wants fx = fy = 254.32 and the code used 288 and 216 -- x squeezed
    /// by 11.7 %, y stretched by 17.7 %, the pair off by exactly 4/3.
    ///
    /// The principal point guess was almost exact: 160.00 against 160.30 and
    /// 120.00 against 119.98, three tenths of a pixel, 3.5 mm at three metres.
    private var depthIntrinsics: (fx: Float, fy: Float, cx: Float, cy: Float)?

    override init() {
        // Load saved IP or use default
        self.rosBridgeHost = RosBridgeDefaults.savedOrCurrentHost()
        super.init()
        print("☁️ PointCloudClient initialized (not started yet)")
        print("☁️ Will connect to: ws://\(rosBridgeHost):\(rosBridgePort)")
        print("☁️ Will publish to topic: \(topicName)")
    }

    deinit {
        stopServerImmediate()
    }

    func startServer() {
        guard !isRunning else {
            print("☁️ Client already running")
            return
        }

        isRunning = true
        frameCount = 0

        print("☁️ ========== Connecting to ROS2 Bridge ==========")
        print("☁️ Host: \(rosBridgeHost)")
        print("☁️ Port: \(rosBridgePort)")
        print("☁️ Topic: \(topicName)")

        connectToROSBridge()
    }

    func stopServer() {
        print("☁️ stopServer() called")
        stopServerImmediate()
    }

    private func stopServerImmediate() {
        // Set flag first to prevent any reconnection attempts
        isRunning = false
        isConnected = false

        // Stop timers on main thread immediately
        DispatchQueue.main.async { [weak self] in

            self?.publishTimer?.invalidate()
            self?.publishTimer = nil

            self?.reconnectTimer?.invalidate()
            self?.reconnectTimer = nil
        }

        // Close WebSocket connection
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil

        // Clear current point cloud
        pointCloudQueue.async { [weak self] in
            self?.currentPublishMessage = nil
            self?.finishSend()
        }

        DispatchQueue.main.async { [weak self] in
            self?.isServerRunning = false
            self?.serverURL = "Not Connected"
            self?.connectedClients = 0
        }

        print("☁️ ✅ Disconnected from ROS2 Bridge")
    }

    private func connectToROSBridge() {
        guard isRunning else { return }

        let urlString = "ws://\(rosBridgeHost):\(rosBridgePort)"

        // Create URL for ROS2 Bridge WebSocket
        guard let url = URL(string: urlString) else {
            print("☁️ ❌ Invalid ROS2 Bridge URL: \(urlString)")
            return
        }

        print("☁️ 📡 Connecting to ROS2 Bridge at: \(urlString)")

        // Cancel any existing session
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        urlSession?.invalidateAndCancel()

        // Create URLSession with delegate
        let config = URLSessionConfiguration.default
        // timeoutIntervalForResource caps how long the whole task may live,
        // and a websocket task lives as long as its connection -- so 60 here
        // was a scheduled execution, not a safety net. It showed up on the
        // bridge as a new client every 60 to 73 seconds, climbing to eight
        // over one recording while the old ones were never cleaned up, and in
        // the phone log as -1001 "The request timed out" on a link that was
        // carrying 5 Hz of point clouds a moment earlier. A session runs for
        // minutes; give the connection a day.
        //
        // The request timeout can also fire between messages on a quiet link,
        // and rosbridge sends a publisher nothing at all, so 10 s was tight
        // for a connection that only ever talks.
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 86400
        config.waitsForConnectivity = false
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue())

        // Create WebSocket task
        webSocketTask = urlSession?.webSocketTask(with: url)

        // Start connection
        webSocketTask?.resume()

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.serverURL = "Connecting to \(self.rosBridgeHost)..."
        }

        // Start receiving messages
        receiveMessage()
    }

    private func receiveMessage() {
        guard isRunning else { return }

        webSocketTask?.receive { [weak self] result in
            guard let self = self, self.isRunning else { return }

            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    if Int.random(in: 0..<50) == 0 {
                        print("☁️ 📥 Received from ROS2 Bridge: \(text.prefix(100))...")
                    }
                case .data(let data):
                    print("☁️ 📥 Received binary data: \(data.count) bytes")
                @unknown default:
                    break
                }

                // Continue receiving only if still running
                if self.isRunning {
                    self.receiveMessage()
                }

            case .failure(let error):
                if self.isRunning {
                    print("☁️ ❌ WebSocket receive error: \(error)")
                    self.handleDisconnection()
                }
            }
        }
    }

    private func handleConnectionSuccess() {
        guard isRunning else { return }

        isConnected = true

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.isServerRunning = true
            self.connectedClients = 1
            self.serverURL = "ws://\(self.rosBridgeHost):\(self.rosBridgePort)"
            print("☁️ ✅ Connected to ROS2 Bridge at \(self.serverURL)")
        }

        // Advertise the topic
        advertiseTopic()

        // Start publishing timer
        startPublishing()
    }

    private func handleDisconnection() {
        // Don't do anything if we're not supposed to be running
        guard isRunning else { return }

        isConnected = false

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isServerRunning = false
            self.connectedClients = 0
            self.serverURL = "Reconnecting to \(self.rosBridgeHost)..."
        }

        // Stop publish timer
        DispatchQueue.main.async { [weak self] in
            self?.publishTimer?.invalidate()
            self?.publishTimer = nil
        }

        // Schedule reconnection only if we're still supposed to be running
        if isRunning {
            scheduleReconnect()
        }
    }

    private func scheduleReconnect() {
        guard isRunning else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRunning else { return }

            self.reconnectTimer?.invalidate()
            self.reconnectTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
                guard let self = self, self.isRunning else { return }
                print("☁️ 🔄 Attempting to reconnect to ROS2 Bridge...")
                self.connectToROSBridge()
            }
        }
    }

    private func advertiseTopic() {
        guard isRunning && isConnected else { return }

        // Advertise PointCloud2 topic to ROS2 Bridge
        let advertiseMsg: [String: Any] = [
            "op": "advertise",
            "topic": topicName,
            "type": "sensor_msgs/msg/PointCloud2"
        ]

        sendJSON(advertiseMsg)
        print("☁️ 📢 Advertised topic: \(topicName)")
    }

    private func startPublishing() {
        guard isRunning else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRunning else { return }

            self.publishTimer?.invalidate()
            self.publishTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / self.publishRate, repeats: true) { [weak self] timer in
                guard let self = self, self.isRunning else {
                    timer.invalidate()
                    return
                }
                self.publishPointCloud()
            }

            print("☁️ ▶️ Started publishing at \(self.publishRate) Hz")
        }
    }

    private func publishPointCloud() {
        guard isRunning && isConnected else { return }

        pointCloudQueue.async { [weak self] in
            guard let self = self, self.isRunning,
                  let jsonString = self.currentPublishMessage else { return }

            // Send the pre-built JSON string directly (no re-serialization)
            self.sendString(jsonString, dropsWhenBusy: true)
        }
    }

    private func sendJSON(_ dict: [String: Any]) {
        guard isRunning else { return }

        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let jsonString = String(data: data, encoding: .utf8) else {
            return
        }

        sendString(jsonString)
    }

    private func sendString(_ jsonString: String, dropsWhenBusy: Bool = false) {
        guard isRunning else { return }
        guard let task = webSocketTask else { return }

        if dropsWhenBusy {
            guard tryBeginSend() else { return }
        }

        let message = URLSessionWebSocketTask.Message.string(jsonString)

        task.send(message) { [weak self] error in
            guard let self = self else { return }
            if dropsWhenBusy {
                self.finishSend()
            }

            guard self.isRunning else { return }

            if let error = error {
                print("☁️ ❌ Failed to send message: \(error)")
                self.handleDisconnection()
            }
        }
    }

    private func tryBeginSend() -> Bool {
        sendStateLock.lock()
        defer { sendStateLock.unlock() }

        guard !isSending else { return false }
        isSending = true
        return true
    }

    private func finishSend() {
        sendStateLock.lock()
        isSending = false
        sendStateLock.unlock()
    }

    private func tryBeginDepthProcessing() -> Bool {
        depthProcessingLock.lock()
        defer { depthProcessingLock.unlock() }

        guard !isProcessingDepth else { return false }
        isProcessingDepth = true
        return true
    }

    private func setProcessingDepth(_ value: Bool) {
        depthProcessingLock.lock()
        isProcessingDepth = value
        depthProcessingLock.unlock()
    }

    // MARK: - ROS2 PointCloud2 JSON Generation

    /// Build the complete rosbridge publish JSON string directly.
    /// This avoids the old pattern of: build dict -> serialize -> store ->
    /// deserialize -> wrap in publish dict -> re-serialize.
    /// Now we serialize once and store the ready-to-send string.
    private func buildPublishMessage(points: UnsafeBufferPointer<Float>) -> String? {
        let pointCount = points.count / 3
        guard pointCount > 0, let pointsBaseAddress = points.baseAddress else { return nil }

        let now = Date()
        let timestamp = now.timeIntervalSince1970
        let sec = Int(timestamp)
        let nanosec = Int((timestamp - Double(sec)) * 1_000_000_000)

        sequenceCounter += 1

        // Build binary data efficiently using pre-allocated buffer
        let byteCount = pointCount * 12  // 3 floats * 4 bytes each
        binaryBuffer = Data(count: byteCount)
        binaryBuffer.withUnsafeMutableBytes { rawBuffer in
            guard let dest = rawBuffer.baseAddress?.assumingMemoryBound(to: Float.self) else { return }
            // Direct memory copy from source points buffer
            memcpy(dest, pointsBaseAddress, byteCount)
        }

        // Base64 encode
        let base64Data = binaryBuffer.base64EncodedString()
        let rowStep = pointCount * 12

        // Build the complete publish JSON string directly using string interpolation
        // This is much faster than JSONSerialization for a known fixed structure
        let json = """
        {"op":"publish","topic":"\(topicName)","msg":{"header":{"stamp":{"sec":\(sec),"nanosec":\(nanosec)},"frame_id":"person_camera_depth_optical_frame"},"height":1,"width":\(pointCount),"fields":[{"name":"x","offset":0,"datatype":7,"count":1},{"name":"y","offset":4,"datatype":7,"count":1},{"name":"z","offset":8,"datatype":7,"count":1}],"is_bigendian":false,"point_step":12,"row_step":\(rowStep),"data":"\(base64Data)","is_dense":true}}
        """

        return json
    }

    // MARK: - Depth Data Processing

    // Reusable flat float array [x0,y0,z0, x1,y1,z1, ...] to avoid tuple overhead
    private var pointsBuffer: [Float] = []

    private func processDepthData(_ depthData: AVDepthData) {
        guard isRunning else { return }
        guard tryBeginDepthProcessing() else { return }

        pointCloudQueue.async { [weak self] in
            guard let self = self else { return }
            defer { self.setProcessingDepth(false) }
            guard self.isRunning else { return }

            let pointCount = self.extractPointsFromDepth(depthData)
            if pointCount > 0 {
                self.pointsBuffer.withUnsafeBufferPointer { buffer in
                    guard let baseAddress = buffer.baseAddress else { return }
                    let usedPoints = UnsafeBufferPointer(start: baseAddress, count: pointCount * 3)
                    if let msg = self.buildPublishMessage(points: usedPoints) {
                        self.currentPublishMessage = msg
                    }
                }

                self.frameCount += 1
                if self.frameCount % 30 == 0 {
                    let msgSize = self.currentPublishMessage?.utf8.count ?? 0
                    print("☁️ PointCloud2 #\(self.frameCount): \(pointCount) points, msg: \(msgSize / 1024)KB, topic: \(self.topicName)")
                }
            }
        }
    }

    /// Extract points directly into flat Float array. Returns point count.
    /// Uses pointsBuffer as [x0,y0,z0, x1,y1,z1, ...] layout matching PointCloud2 binary format.
    private func extractPointsFromDepth(_ depthData: AVDepthData) -> Int {
        let depthMap = depthData.depthDataMap

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
        }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            return 0
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let pixelFormat = CVPixelBufferGetPixelFormatType(depthMap)

        // Measured intrinsics when the hardware has reported them, the old
        // guesses only until it does -- which is the first video frame, so in
        // practice only a frame or two ever uses them.
        let fx: Float, fy: Float, cx: Float, cy: Float
        if let k = depthIntrinsics {
            fx = k.fx; fy = k.fy; cx = k.cx; cy = k.cy
        } else {
            fx = Float(width) * 0.9
            fy = Float(height) * 0.9
            cx = Float(width) / 2.0
            cy = Float(height) / 2.0
        }

        // Pre-allocate buffer for max possible points
        let maxPoints = ((width + sampleStep - 1) / sampleStep) * ((height + sampleStep - 1) / sampleStep)
        if pointsBuffer.count < maxPoints * 3 {
            pointsBuffer = [Float](repeating: 0, count: maxPoints * 3)
        }

        var writeIndex = 0

        if pixelFormat == kCVPixelFormatType_DepthFloat32 ||
           pixelFormat == kCVPixelFormatType_DisparityFloat32 {
            let floatBuffer = baseAddress.assumingMemoryBound(to: Float32.self)
            let floatsPerRow = bytesPerRow / MemoryLayout<Float32>.stride
            let isDisparity = pixelFormat == kCVPixelFormatType_DisparityFloat32

            for row in stride(from: 0, to: height, by: sampleStep) {
                let rowBase = row * floatsPerRow
                for col in stride(from: 0, to: width, by: sampleStep) {
                    var depth = floatBuffer[rowBase + col]

                    if isDisparity && depth > 0 {
                        depth = 1.0 / depth
                    }

                    if depth > 0.1 && depth < 5.0 {
                        pointsBuffer[writeIndex]     = (Float(col) - cx) * depth / fx
                        pointsBuffer[writeIndex + 1] = (Float(row) - cy) * depth / fy
                        pointsBuffer[writeIndex + 2] = depth
                        writeIndex += 3
                    }
                }
            }
        } else if pixelFormat == kCVPixelFormatType_DepthFloat16 ||
                  pixelFormat == kCVPixelFormatType_DisparityFloat16 {
            let uint16Buffer = baseAddress.assumingMemoryBound(to: UInt16.self)
            let elementsPerRow = bytesPerRow / MemoryLayout<UInt16>.stride
            let isDisparity = pixelFormat == kCVPixelFormatType_DisparityFloat16

            for row in stride(from: 0, to: height, by: sampleStep) {
                let rowBase = row * elementsPerRow
                for col in stride(from: 0, to: width, by: sampleStep) {
                    var depth = float16ToFloat32(uint16Buffer[rowBase + col])

                    if isDisparity && depth > 0 {
                        depth = 1.0 / depth
                    }

                    if depth > 0.1 && depth < 5.0 {
                        pointsBuffer[writeIndex]     = (Float(col) - cx) * depth / fx
                        pointsBuffer[writeIndex + 1] = (Float(row) - cy) * depth / fy
                        pointsBuffer[writeIndex + 2] = depth
                        writeIndex += 3
                    }
                }
            }
        }

        return writeIndex / 3
    }

    private func float16ToFloat32(_ value: UInt16) -> Float {
        let sign = UInt32(value & 0x8000) << 16
        let exponent = ((value & 0x7C00) >> 10)
        let fraction = (value & 0x03FF)

        if exponent == 0 {
            if fraction == 0 {
                return Float(bitPattern: sign)
            }
            let normalized = Float(fraction) / 1024.0 * powf(2, -14)
            return sign != 0 ? -normalized : normalized
        } else if exponent == 0x1F {
            let newExponent = UInt32(0xFF) << 23
            let newFraction = UInt32(fraction) << 13
            return Float(bitPattern: sign | newExponent | newFraction)
        } else {
            let newExponent = (UInt32(exponent) - 15 + 127) << 23
            let newFraction = UInt32(fraction) << 13
            return Float(bitPattern: sign | newExponent | newFraction)
        }
    }

    // MARK: - ARKit Point Cloud Processing

    func processARKitPointCloud(_ pointCloud: ARPointCloud) {
        guard isRunning else { return }

        pointCloudQueue.async { [weak self] in
            guard let self = self, self.isRunning else { return }

            let count = pointCloud.points.count
            // Ensure buffer is large enough
            if self.pointsBuffer.count < count * 3 {
                self.pointsBuffer = [Float](repeating: 0, count: count * 3)
            }

            // Copy ARKit points into flat buffer
            var writeIndex = 0
            for i in 0..<count {
                let point = pointCloud.points[i]
                self.pointsBuffer[writeIndex]     = point.x
                self.pointsBuffer[writeIndex + 1] = point.y
                self.pointsBuffer[writeIndex + 2] = point.z
                writeIndex += 3
            }

            self.pointsBuffer.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                let usedPoints = UnsafeBufferPointer(start: baseAddress, count: count * 3)
                if let msg = self.buildPublishMessage(points: usedPoints) {
                    self.currentPublishMessage = msg
                }
            }

            self.frameCount += 1
            if self.frameCount % 30 == 0 {
                print("☁️ PointCloud2 from ARKit #\(self.frameCount): \(count) points")
            }
        }
    }
}

// MARK: - URLSessionWebSocketDelegate
extension PointCloudServer: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard isRunning else { return }
        print("☁️ ✅ WebSocket connection opened to \(rosBridgeHost):\(rosBridgePort)")
        handleConnectionSuccess()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard isRunning else { return }
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "unknown"
        print("☁️ ⚠️ WebSocket connection closed with code: \(closeCode), reason: \(reasonString)")
        handleDisconnection()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard isRunning else { return }
        if let error = error {
            let nsError = error as NSError
            print("☁️ ❌ WebSocket connection failed!")
            print("☁️ ❌ Error domain: \(nsError.domain), code: \(nsError.code)")
            print("☁️ ❌ Error description: \(error.localizedDescription)")

            // Provide more specific error messages
            if nsError.domain == NSURLErrorDomain {
                switch nsError.code {
                case NSURLErrorTimedOut:
                    print("☁️ ❌ Connection timed out - check if ROS2 Bridge is running at \(rosBridgeHost):\(rosBridgePort)")
                case NSURLErrorCannotConnectToHost:
                    print("☁️ ❌ Cannot connect to host - check IP address and ensure ROS2 Bridge is running")
                case NSURLErrorNetworkConnectionLost:
                    print("☁️ ❌ Network connection lost")
                case NSURLErrorNotConnectedToInternet:
                    print("☁️ ❌ Not connected to internet/network")
                default:
                    print("☁️ ❌ Network error code: \(nsError.code)")
                }
            }
            handleDisconnection()
        }
    }
}

// MARK: - PointCloudDelegate
extension PointCloudServer: PointCloudDelegate {
    func setDepthIntrinsics(fx: Float, fy: Float, cx: Float, cy: Float) {
        depthIntrinsics = (fx, fy, cx, cy)
        print(String(format: "☁️ Point cloud now using measured intrinsics "
                     + "fx %.2f fy %.2f cx %.2f cy %.2f", fx, fy, cx, cy))
    }

    func didCaptureDepthData(_ depthData: AVDepthData) {
        guard isRunning else { return }

        if frameCount % 60 == 0 {
            let depthMap = depthData.depthDataMap
            let width = CVPixelBufferGetWidth(depthMap)
            let height = CVPixelBufferGetHeight(depthMap)
            print("☁️ Processing depth data: \(width)x\(height), sampleStep: \(sampleStep), frame #\(frameCount)")
        }

        processDepthData(depthData)
    }
}
