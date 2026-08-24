//
//  CameraManager.swift
//  Unitree
//
//  Created by vision4blind on 20.10.25.
//

import AVFoundation
import UIKit

class CameraManager: NSObject, ObservableObject {
    @Published var isSessionRunning = false
    @Published var authorizationStatus: AVAuthorizationStatus = .notDetermined
    @Published var error: String?

    // Expose captureSession for preview
    let captureSession = AVCaptureSession()
    private var videoOutput: AVCaptureVideoDataOutput?
    private var depthOutput: AVCaptureDepthDataOutput?
    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    private var outputSynchronizer: AVCaptureDataOutputSynchronizer?

    // Video streaming delegate
    weak var streamDelegate: VideoStreamDelegate?

    // Point cloud delegate
    weak var pointCloudDelegate: PointCloudDelegate?

    // ROS frame delegate for publishing RGBD topics
    weak var rosFrameDelegate: RosFrameDelegate?

    // Local recorder delegate: receives full-resolution frames for archival mp4
    weak var localVideoDelegate: LocalVideoFrameDelegate?

    private var isCameraSetup = false

    // 视频输出连接，用于动态调整方向
    private var videoConnection: AVCaptureConnection?

    override init() {
        super.init()
        // Initialize authorization status asynchronously to avoid blocking
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.checkAuthorization()
        }

        // 禁用自动方向调整，保持固定的1280x720分辨率
        // 注释掉方向监听以保持固定分辨率
        /*
        // 监听设备方向变化
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(deviceOrientationDidChange),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )

        // 开始设备方向监测
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        */
    }

    deinit {
        // 清理资源（方向监听已禁用）
        // NotificationCenter.default.removeObserver(self)
        // UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    @objc private func deviceOrientationDidChange() {
        updateVideoOrientation()
    }

    private func updateVideoOrientation() {
        sessionQueue.async { [weak self] in
            guard let self = self, let connection = self.videoConnection else {
                return
            }

            let deviceOrientation = UIDevice.current.orientation

            // 忽略无效的方向
            guard deviceOrientation != .unknown &&
                  deviceOrientation != .faceUp &&
                  deviceOrientation != .faceDown else {
                return
            }

            let videoRotationAngle: CGFloat

            switch deviceOrientation {
            case .portrait:
                videoRotationAngle = 90
            case .portraitUpsideDown:
                videoRotationAngle = 270
            case .landscapeLeft:
                videoRotationAngle = 180
            case .landscapeRight:
                videoRotationAngle = 0
            default:
                return
            }

            if #available(iOS 17.0, *) {
                if connection.isVideoRotationAngleSupported(videoRotationAngle) {
                    connection.videoRotationAngle = videoRotationAngle
                    print("📱 Video orientation updated to \(videoRotationAngle)° for device orientation: \(deviceOrientation.rawValue)")

                    // 通知流服务器需要重新配置编码器
                    self.streamDelegate?.videoOrientationDidChange()
                }
            } else {
                // iOS 16 及更早版本的兼容性处理
                let videoOrientation: AVCaptureVideoOrientation
                switch deviceOrientation {
                case .portrait:
                    videoOrientation = .portrait
                case .portraitUpsideDown:
                    videoOrientation = .portraitUpsideDown
                case .landscapeLeft:
                    videoOrientation = .landscapeRight
                case .landscapeRight:
                    videoOrientation = .landscapeLeft
                default:
                    return
                }

                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = videoOrientation
                    print("📱 Video orientation updated to \(videoOrientation.rawValue) for device orientation: \(deviceOrientation.rawValue)")

                    // 通知流服务器需要重新配置编码器
                    self.streamDelegate?.videoOrientationDidChange()
                }
            }
        }
    }

    func checkAuthorization() {
        let status = AVCaptureDevice.authorizationStatus(for: .video)

        DispatchQueue.main.async { [weak self] in
            self?.authorizationStatus = status

            switch status {
            case .authorized:
                // Don't setup camera here, wait for explicit start
                print("✅ Camera access authorized")
            case .notDetermined:
                self?.requestAuthorization()
            case .denied, .restricted:
                self?.error = "Camera access denied. Please allow access in Settings."
                print("❌ Camera access denied")
            @unknown default:
                self?.error = "Unknown authorization status"
            }
        }
    }

    private func requestAuthorization() {
        print("📱 Requesting camera access...")
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            DispatchQueue.main.async {
                if granted {
                    self?.authorizationStatus = .authorized
                    print("✅ Camera access granted")
                } else {
                    self?.authorizationStatus = .denied
                    self?.error = "Camera access denied"
                    print("❌ Camera access denied by user")
                }
            }
        }
    }

    // Synchronous setup (must be called on sessionQueue)
    // Returns true if setup succeeded, false otherwise
    private func setupCameraSync() -> Bool {
        print("📸 Setting up camera...")
        print("🆕 CODE VERSION: 2.0 - DEPTH SUPPORT ENABLED 🆕")

        captureSession.beginConfiguration()
        defer {
            captureSession.commitConfiguration()
        }

        // Don't set preset yet, we'll configure format manually for depth support

        // Try to get device with depth capability first
        print("📊 ========== Searching for Camera Devices ==========")

        // List all available devices
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInLiDARDepthCamera,
                .builtInDualCamera,
                .builtInDualWideCamera,
                .builtInTripleCamera,
                .builtInTrueDepthCamera,
                .builtInWideAngleCamera
            ],
            mediaType: .video,
            position: .back
        )

        print("📊 Found \(discoverySession.devices.count) camera devices:")
        for (index, device) in discoverySession.devices.enumerated() {
            print("📊   Device \(index): \(device.localizedName)")
            print("📊     Type: \(device.deviceType.rawValue)")
            print("📊     Position: \(device.position.rawValue)")
            print("📊     Formats: \(device.formats.count)")
            print("📊     Has depth: \(device.activeFormat.supportedDepthDataFormats.count > 0)")
        }

        // Try to select the best camera for depth
        var videoDevice: AVCaptureDevice?

        // Priority 1: LiDAR depth camera
        if let lidarDevice = AVCaptureDevice.default(.builtInLiDARDepthCamera, for: .video, position: .back) {
            videoDevice = lidarDevice
            print("✅ Selected LiDAR depth camera")
        }
        // Priority 2: Triple camera (iPhone 11/12/13 Pro)
        else if let tripleCamera = AVCaptureDevice.default(.builtInTripleCamera, for: .video, position: .back) {
            videoDevice = tripleCamera
            print("✅ Selected triple camera")
        }
        // Priority 3: Dual wide camera
        else if let dualWideCamera = AVCaptureDevice.default(.builtInDualWideCamera, for: .video, position: .back) {
            videoDevice = dualWideCamera
            print("✅ Selected dual wide camera")
        }
        // Priority 4: Dual camera
        else if let dualCamera = AVCaptureDevice.default(.builtInDualCamera, for: .video, position: .back) {
            videoDevice = dualCamera
            print("✅ Selected dual camera")
        }
        // Fallback: Wide angle camera
        else if let wideAngle = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) {
            videoDevice = wideAngle
            print("⚠️ Selected wide angle camera (may not support depth)")
        }

        guard let selectedDevice = videoDevice else {
            print("❌ Cannot access any rear camera")
            DispatchQueue.main.async {
                self.error = "Unable to access rear camera"
            }
            return false
        }

        print("✅ Got camera device: \(selectedDevice.localizedName)")
        print("📊 Device model: \(selectedDevice.modelID)")
        print("📊 Device type: \(selectedDevice.deviceType.rawValue)")
        print("📊 Device has depth in active format: \(selectedDevice.activeFormat.supportedDepthDataFormats.count > 0)")
        print("📊 ================================================")

        // Add video input first
        do {
            let videoInput = try AVCaptureDeviceInput(device: selectedDevice)
            if captureSession.canAddInput(videoInput) {
                captureSession.addInput(videoInput)
                print("✅ Added video input")
            } else {
                print("❌ Cannot add video input")
                DispatchQueue.main.async {
                    self.error = "Cannot add video input"
                }
                return false
            }
        } catch {
            print("❌ Failed to create video input: \(error.localizedDescription)")
            DispatchQueue.main.async {
                self.error = "Failed to create video input"
            }
            return false
        }

        // Now try to find a format that supports depth data
        var selectedFormat: AVCaptureDevice.Format?
        var hasDepthSupport = false

        print("📊 ========== Scanning Available Formats ==========")
        print("📊 Total formats available: \(selectedDevice.formats.count)")

        var depthFormatsCount = 0

        // Print first 10 formats in detail for debugging
        print("📊 Detailed format information (first 10):")
        for (index, format) in selectedDevice.formats.prefix(10).enumerated() {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let depthFormats = format.supportedDepthDataFormats
            let mediaType = format.formatDescription.mediaSubType
            print("📊   Format \(index): \(dimensions.width)x\(dimensions.height), mediaType: \(mediaType), depth formats: \(depthFormats.count)")
        }

        for (index, format) in selectedDevice.formats.enumerated() {
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let supportsDepth = format.supportedDepthDataFormats.count > 0

            if supportsDepth {
                depthFormatsCount += 1
                print("📊 Format \(index): \(dimensions.width)x\(dimensions.height) - ✅ DEPTH SUPPORTED (\(format.supportedDepthDataFormats.count) depth formats)")

                // Print depth format details
                for (depthIdx, depthFormat) in format.supportedDepthDataFormats.enumerated() {
                    let depthDims = CMVideoFormatDescriptionGetDimensions(depthFormat.formatDescription)
                    print("📊     Depth format \(depthIdx): \(depthDims.width)x\(depthDims.height)")
                }
            }

            // Look for formats that support depth
            // Prefer 1920x1440 for iPhone 12 Pro Max LiDAR
            if supportsDepth {
                if dimensions.width == 1920 && dimensions.height == 1440 {
                    selectedFormat = format
                    hasDepthSupport = true
                    print("📊 ⭐ Selected 1920x1440 format for depth capability")
                } else if selectedFormat == nil {
                    // Take first depth-capable format if we haven't found 1920x1440
                    selectedFormat = format
                    hasDepthSupport = true
                    print("📊 ⭐ Selected \(dimensions.width)x\(dimensions.height) format for depth capability")
                }
            }
        }

        print("📊 Found \(depthFormatsCount) formats with depth support")
        print("📊 ================================================")

        // Configure the selected format
        if let format = selectedFormat {
            do {
                try selectedDevice.lockForConfiguration()
                selectedDevice.activeFormat = format
                let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                print("✅ Set active format to: \(dimensions.width)x\(dimensions.height) with depth support")
                selectedDevice.unlockForConfiguration()
            } catch {
                print("⚠️ Could not set format: \(error)")
                hasDepthSupport = false
            }
        } else {
            print("⚠️ No depth-capable formats found")
        }

        // Add video output
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.alwaysDiscardsLateVideoFrames = true

        // If we have depth support, use native resolution; otherwise use fixed 1280x720
        if hasDepthSupport {
            // Use native format resolution to maintain depth synchronization
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
            print("📊 Using native resolution for depth compatibility")
        } else {
            // Use fixed resolution 1280x720 with specific pixel format
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: 1280,
                kCVPixelBufferHeightKey as String: 720
            ]
            print("📊 Using fixed 1280x720 resolution (no depth)")
        }

        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
            self.videoOutput = videoOutput
            print("✅ Added video output")
        } else {
            print("❌ Cannot add video output")
            DispatchQueue.main.async {
                self.error = "Cannot add video output"
            }
            return false
        }

        // Try to add depth data output if available
        if selectedDevice.activeFormat.supportedDepthDataFormats.count > 0 {
            print("📊 Device supports depth data, configuring...")

            // Find a depth format that matches video dimensions
            let depthFormats = selectedDevice.activeFormat.supportedDepthDataFormats
            let selectedDepthFormat = depthFormats.last

            do {
                try selectedDevice.lockForConfiguration()
                selectedDevice.activeDepthDataFormat = selectedDepthFormat
                selectedDevice.unlockForConfiguration()
                if let format = selectedDepthFormat {
                    print("✅ Depth format configured: \(format)")
                } else {
                    print("✅ Depth format configured")
                }
            } catch {
                print("⚠️ Could not set depth format: \(error)")
            }

            // Add depth output
            let depthOutput = AVCaptureDepthDataOutput()
            depthOutput.isFilteringEnabled = true

            if captureSession.canAddOutput(depthOutput) {
                captureSession.addOutput(depthOutput)
                self.depthOutput = depthOutput
                print("✅ Added depth output")

                // Setup output synchronizer for video and depth
                let outputQueue = DispatchQueue(label: "camera.output.queue", qos: .userInitiated)
                let synchronizer = AVCaptureDataOutputSynchronizer(dataOutputs: [videoOutput, depthOutput])
                synchronizer.setDelegate(self, queue: outputQueue)
                self.outputSynchronizer = synchronizer
                print("✅ Output synchronizer configured for video and depth")
            } else {
                print("⚠️ Cannot add depth output, using video only")
                // Fall back to video only
                let outputQueue = DispatchQueue(label: "camera.video.output.queue", qos: .userInitiated)
                videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
                print("✅ Video output delegate configured (no depth)")
            }
        } else {
            print("⚠️ Device does not support depth data, using video only")
            // Set video output delegate
            let outputQueue = DispatchQueue(label: "camera.video.output.queue", qos: .userInitiated)
            videoOutput.setSampleBufferDelegate(self, queue: outputQueue)
            print("✅ Video output delegate configured (no depth)")
        }

        // 获取视频输出连接并设置固定方向为横屏（保持1280x720）
        if let connection = videoOutput.connection(with: .video) {
            self.videoConnection = connection

            // 固定为横屏方向，确保输出始终是1280x720
            if #available(iOS 17.0, *) {
                // 设置为0度（横屏右）
                connection.videoRotationAngle = 0
                print("✅ Video orientation fixed to 0° (Landscape Right) for 1280x720 output")
            } else {
                // iOS 16 及更早版本
                if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .landscapeRight
                    print("✅ Video orientation fixed to Landscape Right for 1280x720 output")
                }
            }
        } else {
            print("⚠️ Could not get video connection")
        }

        print("✅ Camera setup complete")

        DispatchQueue.main.async {
            self.error = nil
        }

        return true
    }

    func startSession() {
        print("🎬 ========================================")
        print("🎬 startSession() called")
        print("📋 Current isSessionRunning: \(isSessionRunning)")
        print("📋 Current captureSession.isRunning: \(captureSession.isRunning)")

        // Check and request permission if needed
        let currentStatus = AVCaptureDevice.authorizationStatus(for: .video)
        print("📋 Authorization status: \(currentStatus.rawValue) (0=notDetermined, 3=authorized)")

        if currentStatus == .notDetermined {
            print("⚠️ Requesting camera permission...")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                print("📱 Permission granted: \(granted)")
                if granted {
                    DispatchQueue.main.async {
                        self?.authorizationStatus = .authorized
                        // Retry immediately after permission granted
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            print("🔄 Retrying start after permission grant...")
                            self?.startSession()
                        }
                    }
                } else {
                    DispatchQueue.main.async {
                        self?.authorizationStatus = .denied
                    }
                }
            }
            return
        }

        if currentStatus != .authorized {
            print("❌ Camera not authorized: \(currentStatus.rawValue)")
            DispatchQueue.main.async {
                self.error = "Camera access denied"
            }
            return
        }

        print("✅ Camera authorized, starting session...")

        sessionQueue.async { [weak self] in
            print("🔧 [SessionQueue] Starting async work...")
            guard let self = self else {
                print("❌ [SessionQueue] Self is nil, aborting")
                return
            }

            print("🔧 [SessionQueue] isCameraSetup = \(self.isCameraSetup)")

            // Setup camera if not already done
            if !self.isCameraSetup {
                print("📸 [SessionQueue] Setting up camera for the first time...")
                let setupSuccess = self.setupCameraSync()

                if !setupSuccess {
                    print("❌ [SessionQueue] Camera setup failed, aborting start")
                    DispatchQueue.main.async {
                        self.isSessionRunning = false
                    }
                    return
                }

                self.isCameraSetup = true
                print("✅ [SessionQueue] Camera setup marked as complete")

                // Give a small delay after setup before starting
                Thread.sleep(forTimeInterval: 0.1)
            } else {
                print("ℹ️ [SessionQueue] Camera already set up, skipping setup")
            }

            print("🔧 [SessionQueue] About to check captureSession.isRunning...")
            print("🔧 [SessionQueue] captureSession.isRunning = \(self.captureSession.isRunning)")

            // Now start the session
            if !self.captureSession.isRunning {
                print("▶️ [SessionQueue] Starting capture session...")
                print("▶️ [SessionQueue] Calling captureSession.startRunning()...")
                self.captureSession.startRunning()
                print("▶️ [SessionQueue] captureSession.startRunning() returned")

                // Wait for session to fully start and verify multiple times
                var attempts = 0
                let maxAttempts = 10
                var sessionStarted = false

                print("🔍 [SessionQueue] Starting verification loop...")
                while attempts < maxAttempts && !sessionStarted {
                    Thread.sleep(forTimeInterval: 0.1)
                    attempts += 1
                    sessionStarted = self.captureSession.isRunning
                    print("📊 [SessionQueue] Attempt \(attempts)/\(maxAttempts): isRunning = \(sessionStarted)")
                }

                // Verify session is actually running
                if self.captureSession.isRunning {
                    print("✅✅✅ [SessionQueue] Camera session STARTED successfully after \(attempts) attempts")
                    print("✅✅✅ [SessionQueue] Updating UI to show camera active...")
                    // Update UI only after session is actually running
                    DispatchQueue.main.async {
                        print("✅✅✅ [MainQueue] Setting isSessionRunning = true")
                        self.isSessionRunning = true
                        print("✅✅✅ [MainQueue] isSessionRunning is now: \(self.isSessionRunning)")
                    }
                } else {
                    print("❌❌❌ [SessionQueue] Camera session FAILED to start after \(maxAttempts) attempts")
                    DispatchQueue.main.async {
                        self.isSessionRunning = false
                        self.error = "Failed to start camera"
                    }
                }
            } else {
                print("ℹ️ [SessionQueue] Camera session already running")
                // Ensure UI state is in sync
                DispatchQueue.main.async {
                    self.isSessionRunning = true
                }
            }

            print("🔧 [SessionQueue] Async work complete")
        }
    }

    func stopSession() {
        print("🛑 Stopping camera session...")

        // Update UI immediately to provide responsive feedback
        DispatchQueue.main.async { [weak self] in
            self?.isSessionRunning = false
        }

        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            // Clear video connection reference first
            self.videoConnection = nil

            if self.captureSession.isRunning {
                self.captureSession.stopRunning()
                print("✅ Camera session stopped")
            } else {
                print("ℹ️ Camera session already stopped")
            }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // This is called when using video output without synchronizer (no depth data)
        streamDelegate?.didCaptureVideoFrame(sampleBuffer, depthData: nil)
        rosFrameDelegate?.didCaptureFrame(sampleBuffer, depthData: nil)
        localVideoDelegate?.recordVideoFrame(sampleBuffer)
    }
}

// MARK: - AVCaptureDataOutputSynchronizerDelegate
extension CameraManager: AVCaptureDataOutputSynchronizerDelegate {
    func dataOutputSynchronizer(_ synchronizer: AVCaptureDataOutputSynchronizer,
                                didOutput synchronizedDataCollection: AVCaptureSynchronizedDataCollection) {
        guard let videoOutput = videoOutput else {
            return
        }

        // Get synchronized video and depth data
        guard let syncedVideoData = synchronizedDataCollection.synchronizedData(for: videoOutput) as? AVCaptureSynchronizedSampleBufferData,
              !syncedVideoData.sampleBufferWasDropped else {
            return
        }

        // sampleBuffer is not optional, so access it directly
        let videoSampleBuffer = syncedVideoData.sampleBuffer

        var depthData: AVDepthData? = nil
        if let depthOutput = depthOutput,
           let syncedDepthData = synchronizedDataCollection.synchronizedData(for: depthOutput) as? AVCaptureSynchronizedDepthData,
           !syncedDepthData.depthDataWasDropped {
            depthData = syncedDepthData.depthData
        }

        // Pass video data to video stream server
        streamDelegate?.didCaptureVideoFrame(videoSampleBuffer, depthData: depthData)
        rosFrameDelegate?.didCaptureFrame(videoSampleBuffer, depthData: depthData)
        localVideoDelegate?.recordVideoFrame(videoSampleBuffer)

        // Pass depth data to point cloud server
        if let depthData = depthData {
            pointCloudDelegate?.didCaptureDepthData(depthData)
        } else {
            // Only log occasionally to avoid spam
            if Int.random(in: 0..<100) == 0 {
                print("⚠️ No depth data available in synchronized frame")
            }
        }
    }
}

// MARK: - VideoStreamDelegate Protocol
protocol VideoStreamDelegate: AnyObject {
    func didCaptureVideoFrame(_ sampleBuffer: CMSampleBuffer, depthData: AVDepthData?)
    func videoOrientationDidChange()
}

// MARK: - PointCloudDelegate Protocol
protocol PointCloudDelegate: AnyObject {
    func didCaptureDepthData(_ depthData: AVDepthData)
}

// MARK: - ROS Frame Delegate Protocol
protocol RosFrameDelegate: AnyObject {
    func didCaptureFrame(_ sampleBuffer: CMSampleBuffer, depthData: AVDepthData?)
}

// MARK: - Local Video Recording Delegate Protocol
protocol LocalVideoFrameDelegate: AnyObject {
    /// Called on the camera output queue with each full-resolution video frame.
    func recordVideoFrame(_ sampleBuffer: CMSampleBuffer)
}
