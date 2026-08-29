//
//  ContentView.swift
//  Unitree
//
//  Created by vision4blind on 20.10.25.
//

import SwiftUI
import AVFoundation
import CoreLocation
import Foundation
import UIKit
import Compression

struct ContentView: View {
    @StateObject private var cameraManager = CameraManager()
    @StateObject private var streamServer = VideoStreamServer()
    @StateObject private var pointCloudServer = PointCloudServer()
    @StateObject private var sensorManager = SensorDataManager()
    @State private var previousCameraState = false
    @State private var previousServerURL = "Not Started"
    @State private var previousPointCloudURL = "Not Started"
    @State private var isInitialized = false
    @State private var rosBridgeIP: String = ""
    @State private var showIPConfig = false
    @State private var showSensorPanel = false
    @FocusState private var isIPFieldFocused: Bool
    @StateObject private var sessionLogger = SessionLogger()
    @StateObject private var videoRecorder = LocalVideoRecorder()
    @StateObject private var syncClient = SyncEventClient()
    @StateObject private var imageClient = ImageStreamClient()
    @StateObject private var sensorClient = SensorStreamClient()
    @State private var frameIdx: Int = 0
    // GPS is throttled below the 0.2s meta timer: real GPS only updates ~1 Hz,
    // so publishing every tick produced ~98% duplicate fixes. Keep ~1 Hz.
    @State private var lastGpsPublishTs: Double = 0
    private let gpsPublishInterval: Double = 1.0  // seconds (≈1 Hz)
    // Hoisted out of `body` so it is created once. If declared inline in
    // `.onReceive`, the high-frequency sensorManager updates (10 Hz) recompute
    // `body` faster than 0.2s, recreating the publisher each time and resetting
    // its countdown so it never fires (no IMU/GPS/frame_meta would publish).
    private let metaPublishTimer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                appBackground
                    .ignoresSafeArea(.all)

                if !isInitialized {
                    VStack(spacing: 20) {
                        ProgressView()
                            .scaleEffect(1.5)
                            .tint(.cyan)
                        Text("Initializing...")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    .accessibilityLabel("App is initializing, please wait")
                }

                ScrollViewReader { scrollProxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 12) {
                            previewPane(width: geometry.size.width)
                                .padding(.top, geometry.safeAreaInsets.top + 6)
                                .padding(.horizontal, 20)

                            VStack(spacing: 12) {
                                servicePanel(
                                    icon: "video.fill",
                                    title: "Video Server",
                                    value: streamServer.serverURL,
                                    tint: streamServer.isServerRunning ? videoTint : .gray
                                )

                                pointCloudPanel
                            }
                            .onChange(of: streamServer.serverURL) { oldValue, newValue in
                                if newValue != previousServerURL {
                                    announceServerURLChange(newValue, serverType: "Video")
                                    previousServerURL = newValue
                                }
                            }
                            .onChange(of: pointCloudServer.serverURL) { oldValue, newValue in
                                if newValue != previousPointCloudURL {
                                    announceServerURLChange(newValue, serverType: "Point Cloud")
                                    previousPointCloudURL = newValue
                                }
                            }
                            .padding(.horizontal, 20)

                            cameraStateBar
                                .padding(.horizontal, 20)
                                .onChange(of: cameraManager.isSessionRunning) { oldValue, newValue in
                                    if newValue != previousCameraState {
                                        announceCameraStateChange(newValue)
                                        previousCameraState = newValue
                                    }
                                }

                            primaryControl
                                .padding(.horizontal, 20)

                            Color.clear.frame(height: geometry.safeAreaInsets.bottom + (isIPFieldFocused ? 280 : 92))
                        }
                        .frame(width: geometry.size.width)
                        .frame(minHeight: geometry.size.height)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .opacity(isInitialized ? 1.0 : 0.0)
                    .animation(.easeIn(duration: 0.3), value: isInitialized)
                    .onChange(of: showIPConfig) { _, isShowing in
                        guard isShowing else { return }
                        scrollToIPConfig(with: scrollProxy)
                    }
                    .onChange(of: isIPFieldFocused) { _, isFocused in
                        guard isFocused else { return }
                        scrollToIPConfig(with: scrollProxy)
                    }
                }

                if showSensorPanel {
                    SensorDataPanel(sensorManager: sensorManager) {
                        withAnimation(.easeInOut(duration: 0.24)) {
                            showSensorPanel = false
                        }
                    }
                    .transition(.move(edge: .leading).combined(with: .opacity))
                    .zIndex(2)
                }

                bottomNavigation
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .ignoresSafeArea(.all, edges: .bottom)
                .zIndex(3)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(appBackground)
            .ignoresSafeArea(.all)
        }
        .background(appBackground)
        .ignoresSafeArea(.all)
        .statusBar(hidden: true)
        .onChange(of: showSensorPanel) { _, isShowing in
            if isShowing {
                sensorManager.startUpdates()
            } else {
                if !cameraManager.isSessionRunning {
                    sensorManager.stopUpdates()
                }
            }
        }
        .onTapGesture {
            // Dismiss keyboard when tapping outside
            isIPFieldFocused = false
        }
        .task {
            // Run initialization asynchronously
            print("📱 App appeared, initializing...")
            print("📱 Note: Video server and ROS2 client will NOT start until you press Start")

            // Load saved IP address
            rosBridgeIP = pointCloudServer.rosBridgeHost
            print("📱 Loaded ROS2 Bridge IP: \(rosBridgeIP)")

            // Set delegates directly
            cameraManager.streamDelegate = streamServer
            cameraManager.pointCloudDelegate = pointCloudServer
            cameraManager.rosFrameDelegate = imageClient
            cameraManager.localVideoDelegate = videoRecorder
            print("✅ Set video and point cloud delegates")

            // Publish/log IMU at the full 50 Hz sensor rate, decoupled from the
            // 5 Hz frame_meta/GPS timer.
            sensorManager.onImuSample = { accel, gyro in
                guard cameraManager.isSessionRunning else { return }
                let ts = Date().timeIntervalSince1970
                sessionLogger.logImu(
                    phoneTsUnix: ts,
                    ax: accel.x, ay: accel.y, az: accel.z,
                    gx: gyro.x, gy: gyro.y, gz: gyro.z
                )
                sensorClient.publishImu(
                    phoneTsUnix: ts,
                    ax: accel.x, ay: accel.y, az: accel.z,
                    gx: gyro.x, gy: gyro.y, gz: gyro.z
                )
            }

            // Initialize previous states
            previousCameraState = cameraManager.isSessionRunning
            previousServerURL = streamServer.serverURL
            previousPointCloudURL = pointCloudServer.serverURL

            // Small delay to ensure smooth initialization
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds

            await MainActor.run {
                isInitialized = true
                print("✅ App initialization complete (waiting for Start button)")
            }

            // Announce app ready after UI is shown
            try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
            await MainActor.run {
                announceAction("Ego2 streaming app ready. Press Start to begin.")
            }
            syncClient.rosBridgeHost = pointCloudServer.rosBridgeHost
            imageClient.rosBridgeHost = pointCloudServer.rosBridgeHost
            sensorClient.rosBridgeHost = pointCloudServer.rosBridgeHost
            syncClient.start { event in
                handleSyncEvent(event)
            }
            imageClient.start()
            sensorClient.start()
        }
        .onChange(of: pointCloudServer.rosBridgeHost) { _, host in
            syncClient.stop()
            imageClient.stop()
            sensorClient.stop()
            syncClient.rosBridgeHost = host
            imageClient.rosBridgeHost = host
            sensorClient.rosBridgeHost = host
            syncClient.start { event in
                handleSyncEvent(event)
            }
            imageClient.start()
            sensorClient.start()
        }
        .onReceive(metaPublishTimer) { _ in
            guard cameraManager.isSessionRunning else { return }
            frameIdx += 1
            let ts = Date().timeIntervalSince1970
            sessionLogger.logFrameMeta(frameIdx: frameIdx, phoneTsUnix: ts)
            syncClient.publishFrameMeta(frameIdx: frameIdx, phoneTsUnix: ts)
            // IMU is published at the full 50 Hz sensor rate via
            // sensorManager.onImuSample (wired up in `.task`), not here.
            if let lat = sensorManager.latitude, let lon = sensorManager.longitude,
               ts - lastGpsPublishTs >= gpsPublishInterval {
                lastGpsPublishTs = ts
                sessionLogger.logGps(
                    phoneTsUnix: ts,
                    lat: lat,
                    lon: lon,
                    altM: sensorManager.altitude ?? 0.0,
                    speedMps: sensorManager.speed ?? 0.0,
                    headingDeg: sensorManager.course ?? 0.0
                )
                sensorClient.publishGps(
                    phoneTsUnix: ts,
                    lat: lat,
                    lon: lon,
                    altM: sensorManager.altitude ?? 0.0,
                    speedMps: sensorManager.speed ?? 0.0,
                    headingDeg: sensorManager.course ?? 0.0,
                    hAccM: sensorManager.horizontalAccuracy ?? -1.0,
                    vAccM: sensorManager.verticalAccuracy ?? -1.0
                )
            }
        }
        .onDisappear {
            // Stop when app exits
            print("📱 App disappearing, cleaning up...")
            cameraManager.stopSession()
            streamServer.stopServer()
            pointCloudServer.stopServer()
            sensorManager.stopUpdates()
            syncClient.stop()
            imageClient.stop()
            sensorClient.stop()
            sessionLogger.endSession()
        }
    }

    // MARK: - Layout

    private var appBackground: Color {
        Color(red: 0.035, green: 0.047, blue: 0.063)
    }

    private var cardBackground: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(0.09),
                Color.white.opacity(0.045)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var videoTint: Color {
        Color(red: 0.22, green: 0.52, blue: 1.0)
    }

    private var cloudTint: Color {
        Color(red: 0.72, green: 0.36, blue: 1.0)
    }

    private var topBar: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ego2")
                    .font(.system(size: 34, weight: .bold))
                    .foregroundColor(.white)
                Text(cameraManager.isSessionRunning ? "Streaming" : "Standby")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(cameraManager.isSessionRunning ? .green : .white.opacity(0.55))
            }

            Spacer()

            HStack(spacing: 8) {
                Circle()
                    .fill(cameraManager.isSessionRunning ? Color.green : Color.gray)
                    .frame(width: 10, height: 10)
                Text(cameraManager.isSessionRunning ? "LIVE" : "IDLE")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.9))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.08))
            .clipShape(Capsule())
        }
    }

    private func previewPane(width: CGFloat) -> some View {
        let previewWidth = width - 40
        let previewHeight = min(previewWidth * 0.64, 300)

        return ZStack(alignment: .bottomLeading) {
            if cameraManager.isSessionRunning {
                CameraPreview(session: cameraManager.captureSession)
                    .frame(width: previewWidth, height: previewHeight)
                    .accessibilityLabel("Camera preview")
                    .accessibilityHint("Shows live camera feed with depth data")
                    .accessibilityAddTraits(.isImage)
            } else {
                Rectangle()
                    .fill(Color.white.opacity(0.04))
                    .frame(width: previewWidth, height: previewHeight)
                    .overlay(
                        VStack(spacing: 12) {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 42, weight: .semibold))
                                .foregroundColor(.white.opacity(0.25))
                            Text("Camera Off")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white.opacity(0.45))
                        }
                    )
            }

            HStack(spacing: 8) {
                Image(systemName: cameraManager.isSessionRunning ? "record.circle.fill" : "pause.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                Text(cameraManager.isSessionRunning ? "Camera Active" : "Camera Inactive")
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundColor(cameraManager.isSessionRunning ? .green : .white.opacity(0.65))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.62))
            .clipShape(Capsule())
            .padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(cameraManager.isSessionRunning ? Color.green.opacity(0.65) : Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: cameraManager.isSessionRunning ? Color.green.opacity(0.22) : Color.clear, radius: 14, y: 8)
    }

    private var pointCloudPanel: some View {
        VStack(spacing: 12) {
            servicePanel(
                icon: "point.3.connected.trianglepath.dotted",
                title: "Point Cloud Client",
                value: pointCloudServer.serverURL,
                tint: pointCloudStatusColor,
                trailing: AnyView(configureIPButton)
            )

            if showIPConfig {
                ipConfigPanel
                    .id("ipConfig")
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private func servicePanel(
        icon: String,
        title: String,
        value: String,
        tint: Color,
        trailing: AnyView? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(tint)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(0.22))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white.opacity(0.62))
                    Text(value)
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                        .foregroundColor(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
                }

                Spacer(minLength: 8)

                if let trailing {
                    trailing
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var configureIPButton: some View {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                showIPConfig.toggle()
                if !showIPConfig {
                    isIPFieldFocused = false
                }
            }
        }) {
            Image(systemName: showIPConfig ? "chevron.up" : "gearshape.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(cloudTint)
                .frame(width: 36, height: 36)
                .background(cloudTint.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .disabled(cameraManager.isSessionRunning)
        .opacity(cameraManager.isSessionRunning ? 0.35 : 1.0)
        .accessibilityLabel(showIPConfig ? "Hide IP configuration" : "Configure IP")
    }

    private var ipConfigPanel: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                TextField(RosBridgeDefaults.currentHost, text: $rosBridgeIP)
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .frame(height: 46)
                    .background(Color.black.opacity(0.32))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isIPFieldFocused ? Color.cyan : Color.white.opacity(0.14), lineWidth: 1)
                    )
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($isIPFieldFocused)

                Button(action: {
                    isIPFieldFocused = false
                    if isValidIP(rosBridgeIP) {
                        pointCloudServer.rosBridgeHost = rosBridgeIP
                        withAnimation {
                            showIPConfig = false
                        }
                        announceAction("IP saved: \(rosBridgeIP)")
                    }
                }) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 46, height: 46)
                        .background(isValidIP(rosBridgeIP) ? Color.green : Color.gray.opacity(0.38))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .disabled(!isValidIP(rosBridgeIP))
                .accessibilityLabel("Save IP")
            }

            HStack {
                Text("Port")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45))
                Spacer()
                Text("9090")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
            }
        }
        .padding(14)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(cloudTint.opacity(0.22), lineWidth: 1)
        )
    }

    private var cameraStateBar: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(cameraManager.isSessionRunning ? Color.green : Color.red.opacity(0.72))
                .frame(width: 12, height: 12)
                .shadow(color: cameraManager.isSessionRunning ? .green : .clear, radius: 8)

            Text(cameraManager.isSessionRunning ? "Camera Active" : "Camera Inactive")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white.opacity(0.9))

            Spacer()

            Text(cameraManager.isSessionRunning ? "H.264 + Depth" : "Ready")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.45))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var primaryControl: some View {
        Button(action: {
            handleStartStop()
        }) {
            HStack(spacing: 12) {
                Image(systemName: cameraManager.isSessionRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 20, weight: .bold))

                Text(cameraManager.isSessionRunning ? "Stop" : "Start")
                    .font(.system(size: 21, weight: .bold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(cameraManager.isSessionRunning ? Color.red : videoTint)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: (cameraManager.isSessionRunning ? Color.red : videoTint).opacity(0.32), radius: 12, y: 6)
        }
        .accessibilityLabel(cameraManager.isSessionRunning ? "Stop camera" : "Start camera")
        .accessibilityHint(cameraManager.isSessionRunning ?
            "Double tap to stop the camera and servers" :
            "Double tap to start the camera and servers")
    }

    private var pointCloudStatusColor: Color {
        if pointCloudServer.connectedClients > 0 {
            return .green
        }

        if pointCloudServer.serverURL.contains("onnecting") {
            return .yellow
        }

        return cloudTint
    }

    private var bottomNavigation: some View {
        HStack(spacing: 0) {
            bottomNavigationButton(
                icon: "rectangle.grid.1x2.fill",
                title: "Dashboard",
                isSelected: !showSensorPanel
            ) {
                withAnimation(.easeInOut(duration: 0.24)) {
                    showSensorPanel = false
                }
            }

            bottomNavigationButton(
                icon: "waveform.path.ecg",
                title: "Sensor Data",
                isSelected: showSensorPanel
            ) {
                withAnimation(.easeInOut(duration: 0.24)) {
                    showSensorPanel = true
                    isIPFieldFocused = false
                }
            }
        }
        .frame(height: 58)
        .background(
            Rectangle()
                .fill(Color.black.opacity(0.42))
                .background(.ultraThinMaterial)
        )
    }

    private func bottomNavigationButton(
        icon: String,
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 19, weight: .semibold))
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(isSelected ? videoTint : .white.opacity(0.52))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func scrollToIPConfig(with proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo("ipConfig", anchor: .center)
            }
        }
    }

    // MARK: - Actions

    /// - Parameter sessionName: the recorder's session id when this came from a
    ///   sync event, so the phone's folder matches the bag's. Nil when the
    ///   button was tapped here, which is also the case worth avoiding: start
    ///   from the recorder and both sides begin at one instant under one name.
    private func handleStartStop(sessionName: String? = nil) {
        print("🔘 ========== BUTTON TAPPED ==========")
        print("🔘 Current state: \(cameraManager.isSessionRunning)")

        // Hide IP config and dismiss keyboard
        showIPConfig = false
        isIPFieldFocused = false

        if cameraManager.isSessionRunning {
            print("🔘 >>> STOPPING camera, video server, and ROS2 client")
            cameraManager.stopSession()
            streamServer.stopServer()
            pointCloudServer.stopServer()
            sensorManager.stopUpdates()
            videoRecorder.stop()
            sessionLogger.endSession()
            syncClient.publishRecordStatus(isRecording: false, reason: "manual_or_sync_stop")
            announceAction("Stopping camera and servers")
        } else {
            print("🔘 >>> STARTING camera, video server, and ROS2 client")
            frameIdx = 0
            sessionLogger.startNewSession(named: sessionName)
            if let dir = sessionLogger.sessionDirectory {
                videoRecorder.start(in: dir)
            }
            sensorManager.startUpdates()
            cameraManager.startSession()
            streamServer.startServer()
            pointCloudServer.startServer()
            syncClient.publishRecordStatus(isRecording: true, reason: "manual_or_sync_start")
            announceAction("Starting camera and servers")
        }

        print("🔘 ====================================")
    }

    // MARK: - Accessibility Announcements

    private func announceAction(_ message: String) {
        DispatchQueue.main.async {
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }

    private func announceCameraStateChange(_ isRunning: Bool) {
        let message = isRunning ?
            "Camera started. Now capturing video with depth data." :
            "Camera stopped."
        announceAction(message)
    }

    private func announceServerURLChange(_ url: String, serverType: String) {
        if url.starts(with: "http") || url.starts(with: "ws") {
            announceAction("\(serverType) connected at \(url)")
        } else if url == "Not Started" || url == "Not Connected" {
            announceAction("\(serverType) disconnected")
        }
    }

    // MARK: - IP Validation

    private func isValidIP(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".")
        guard parts.count == 4 else { return false }

        for part in parts {
            guard let num = Int(part), num >= 0, num <= 255 else {
                return false
            }
        }
        return true
    }

    private func handleSyncEvent(_ event: SyncEvent) {
        sessionLogger.logSyncEvent(seq: event.seq, event: event.event, robotTsIso: event.robotTsIso)
        if event.event == "start_recording" && !cameraManager.isSessionRunning {
            handleStartStop(sessionName: event.session)
        } else if event.event == "stop_recording" && cameraManager.isSessionRunning {
            handleStartStop()
        }
    }
}

final class SessionLogger: ObservableObject {
    private var sessionDir: URL?
    /// Current session directory, so other recorders (e.g. local video) can write
    /// into the same folder.
    var sessionDirectory: URL? { sessionDir }
    private let fm = FileManager.default
    // Serial queue so 50 Hz IMU appends never block the main thread while still
    // preserving write order.
    private let ioQueue = DispatchQueue(label: "session.logger.io")

    func startNewSession(named: String? = nil) {
        let ts = DateFormatter.sessionFormatter.string(from: Date())
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else {
            print("❌ Session logger init failed: documents directory unavailable")
            return
        }
        let folder = named ?? "dataset_session_\(ts)"
        let dir = docs.appendingPathComponent(folder, isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            sessionDir = dir
            try writeHeaderIfNeeded(file: "frame_meta.csv", header: "frame_idx,phone_ts_unix\n")
            try writeHeaderIfNeeded(file: "imu.csv", header: "phone_ts_unix,ax,ay,az,gx,gy,gz\n")
            try writeHeaderIfNeeded(file: "gps.csv", header: "phone_ts_unix,lat,lon,alt_m,speed_mps,heading_deg\n")
            try writeHeaderIfNeeded(file: "sync_events.csv", header: "seq,event,robot_ts_iso,phone_ts_unix\n")
            print("📁 Session logger started at: \(dir.path)")
        } catch {
            print("❌ Session logger init failed: \(error)")
        }
    }

    func endSession() {
        sessionDir = nil
    }

    func logFrameMeta(frameIdx: Int, phoneTsUnix: Double) {
        append("frame_meta.csv", "\(frameIdx),\(fmt(phoneTsUnix))\n")
    }

    func logImu(phoneTsUnix: Double, ax: Double, ay: Double, az: Double, gx: Double, gy: Double, gz: Double) {
        append("imu.csv", "\(fmt(phoneTsUnix)),\(ax),\(ay),\(az),\(gx),\(gy),\(gz)\n")
    }

    func logGps(phoneTsUnix: Double, lat: Double, lon: Double, altM: Double, speedMps: Double, headingDeg: Double) {
        append("gps.csv", "\(fmt(phoneTsUnix)),\(lat),\(lon),\(altM),\(speedMps),\(headingDeg)\n")
    }

    func logSyncEvent(seq: Int, event: String, robotTsIso: String) {
        let now = Date().timeIntervalSince1970
        append("sync_events.csv", "\(seq),\(event),\(robotTsIso),\(fmt(now))\n")
    }

    private func writeHeaderIfNeeded(file: String, header: String) throws {
        guard let dir = sessionDir else { return }
        let f = dir.appendingPathComponent(file)
        if !fm.fileExists(atPath: f.path) {
            try header.data(using: .utf8)?.write(to: f)
        }
    }

    private func append(_ file: String, _ line: String) {
        guard let dir = sessionDir else { return }
        let f = dir.appendingPathComponent(file)
        guard let data = line.data(using: .utf8) else { return }
        ioQueue.async {
            if !FileManager.default.fileExists(atPath: f.path) {
                try? data.write(to: f)
                return
            }
            do {
                let fh = try FileHandle(forWritingTo: f)
                try fh.seekToEnd()
                try fh.write(contentsOf: data)
                try fh.close()
            } catch {
                print("❌ append failed for \(file): \(error)")
            }
        }
    }

    private func fmt(_ t: Double) -> String {
        String(format: "%.6f", t)
    }
}

/// Records the full-resolution camera stream to a local `video.mp4` (H.264, high
/// bitrate) plus a `video_frames.csv` that maps every encoded frame to the phone
/// unix clock. This is the archival-quality copy; the rosbridge JPEG stream is
/// only the low-bandwidth online preview.
///
/// `video_frames.csv` columns: `frame_idx,video_pts_sec,phone_ts_unix`
/// - `frame_idx`     : 0-based index in mp4 decode order
/// - `video_pts_sec` : presentation time in the mp4 (seconds from first frame)
/// - `phone_ts_unix` : Date().timeIntervalSince1970 at capture — the SAME clock
///                     as imu.csv / gps.csv / frame_meta.csv / sync_events.csv,
///                     so every modality is alignable, and sync_events.csv ties
///                     that phone clock to the robot clock.
final class LocalVideoRecorder: NSObject, ObservableObject, LocalVideoFrameDelegate {
    @Published private(set) var isRecording = false

    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var firstPTS: CMTime?
    private var frameIdx = 0
    private var csvHandle: FileHandle?
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "local.video.csv.io")

    func start(in dir: URL) {
        lock.lock(); defer { lock.unlock() }
        guard writer == nil else { return }

        let videoURL = dir.appendingPathComponent("video.mp4")
        try? FileManager.default.removeItem(at: videoURL)
        guard let w = try? AVAssetWriter(outputURL: videoURL, fileType: .mp4) else {
            print("❌ LocalVideoRecorder: failed to create AVAssetWriter")
            return
        }
        writer = w
        input = nil
        firstPTS = nil
        frameIdx = 0

        let csvURL = dir.appendingPathComponent("video_frames.csv")
        FileManager.default.createFile(
            atPath: csvURL.path,
            contents: "frame_idx,video_pts_sec,phone_ts_unix\n".data(using: .utf8)
        )
        csvHandle = try? FileHandle(forWritingTo: csvURL)
        csvHandle?.seekToEndOfFile()

        DispatchQueue.main.async { self.isRecording = true }
        print("🎥 LocalVideoRecorder started: \(videoURL.path)")
    }

    // Called on the camera output queue.
    func recordVideoFrame(_ sampleBuffer: CMSampleBuffer) {
        // Capture the wall clock immediately so the timestamp reflects capture
        // time, not when the encoder happens to drain.
        let ts = Date().timeIntervalSince1970

        lock.lock()
        guard let writer = writer else { lock.unlock(); return }

        // Lazily create the input once we know the frame dimensions.
        if input == nil {
            guard let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                lock.unlock(); return
            }
            let dims = CMVideoFormatDescriptionGetDimensions(fmt)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Int(dims.width),
                AVVideoHeightKey: Int(dims.height),
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: 20_000_000 // 20 Mbps, archival quality
                ]
            ]
            let inp = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            inp.expectsMediaDataInRealTime = true
            guard writer.canAdd(inp) else {
                print("❌ LocalVideoRecorder: writer cannot add video input \(dims.width)x\(dims.height)")
                writer.cancelWriting()
                self.writer = nil
                self.input = nil
                self.firstPTS = nil
                lock.unlock()
                return
            }
            writer.add(inp)
            input = inp
        }
        guard let input = input else { lock.unlock(); return }

        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if firstPTS == nil {
            firstPTS = pts
            guard writer.startWriting() else {
                print("❌ LocalVideoRecorder: startWriting failed: \(writer.error?.localizedDescription ?? "unknown error")")
                writer.cancelWriting()
                // `input` and `writer` are shadowed here by the non-optional
                // locals bound above, so the reset must go through `self`.
                self.writer = nil
                self.input = nil
                self.firstPTS = nil
                lock.unlock()
                return
            }
            writer.startSession(atSourceTime: pts)
        }

        let idx = frameIdx
        var appended = false
        if writer.status == .writing && input.isReadyForMoreMediaData {
            appended = input.append(sampleBuffer)
        }
        let relSec = CMTimeGetSeconds(CMTimeSubtract(pts, firstPTS ?? pts))
        if appended { frameIdx += 1 }
        let handle = csvHandle
        lock.unlock()

        if appended, let handle = handle {
            let row = "\(idx),\(String(format: "%.6f", relSec)),\(String(format: "%.6f", ts))\n"
            if let data = row.data(using: .utf8) {
                ioQueue.async { try? handle.write(contentsOf: data) }
            }
        }
    }

    func stop() {
        lock.lock()
        let writerToFinish = writer
        let inputToFinish = input
        let handle = csvHandle
        let hadFrames = firstPTS != nil
        writer = nil
        input = nil
        firstPTS = nil
        csvHandle = nil
        lock.unlock()

        DispatchQueue.main.async { self.isRecording = false }

        if let writerToFinish = writerToFinish, hadFrames {
            inputToFinish?.markAsFinished()
            writerToFinish.finishWriting {
                print("✅ Local video saved: \(writerToFinish.outputURL.path) (status: \(writerToFinish.status.rawValue))")
            }
        } else {
            // No frames were ever appended; nothing to finalize.
            writerToFinish?.cancelWriting()
        }
        ioQueue.async { try? handle?.close() }
    }
}

struct SyncEvent {
    let seq: Int
    let event: String
    let robotTsIso: String
    /// The recorder's own session id, so both sides name the same run the same
    /// thing. Without it the phone stamps its folder from its own clock and the
    /// pair has to be matched by guessing: 20260829 produced
    /// dataset_session_20260829_130646 on the phone against
    /// dataset_session_20260829_130658 in the bag, twelve seconds apart.
    let session: String?
}

final class SyncEventClient: ObservableObject {
    @Published var rosBridgeHost: String = RosBridgeDefaults.savedOrCurrentHost()
    private let rosBridgePort: UInt16 = 9090
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var reconnectTimer: Timer?
    private var isRunning = false
    private var callback: ((SyncEvent) -> Void)?
    private let topicName = "/dataset/sync_event"
    private let frameMetaTopic = "/camera_person/frame_meta"
    private let recordStatusTopic = "/camera_person/record_status"

    func start(onEvent: @escaping (SyncEvent) -> Void) {
        callback = onEvent
        isRunning = true
        connect()
    }

    func stop() {
        isRunning = false
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    private func connect() {
        guard isRunning else { return }
        let urlString = "ws://\(rosBridgeHost):\(rosBridgePort)"
        guard let url = URL(string: urlString) else { return }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        urlSession = URLSession(configuration: config)
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()
        advertiseAndSubscribe()
        receiveLoop()
    }

    private func advertiseAndSubscribe() {
        sendJson([
            "op": "advertise",
            "topic": frameMetaTopic,
            "type": "std_msgs/msg/String"
        ])
        sendJson([
            "op": "advertise",
            "topic": recordStatusTopic,
            "type": "std_msgs/msg/String"
        ])
        let advertise: [String: Any] = [
            "op": "subscribe",
            "topic": topicName,
            "type": "std_msgs/msg/String"
        ]
        sendJson(advertise)
    }

    func publishFrameMeta(frameIdx: Int, phoneTsUnix: Double) {
        let payload = "{\"frame_idx\":\(frameIdx),\"phone_ts_unix\":\(String(format: "%.6f", phoneTsUnix))}"
        sendJson([
            "op": "publish",
            "topic": frameMetaTopic,
            "msg": ["data": payload]
        ])
    }

    func publishRecordStatus(isRecording: Bool, reason: String) {
        let ts = String(format: "%.6f", Date().timeIntervalSince1970)
        let payload = "{\"is_recording\":\(isRecording ? "true" : "false"),\"phone_ts_unix\":\(ts),\"reason\":\"\(reason)\"}"
        sendJson([
            "op": "publish",
            "topic": recordStatusTopic,
            "msg": ["data": payload]
        ])
    }

    private func sendJson(_ obj: [String: Any]) {
        guard let task = webSocketTask else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { err in
            if let err = err {
                print("❌ sync send error: \(err)")
                self.scheduleReconnect()
            }
        }
    }

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let msg):
                if case .string(let text) = msg {
                    self.handleMessage(text)
                }
                self.receiveLoop()
            case .failure(let err):
                print("❌ sync recv error: \(err)")
                self.scheduleReconnect()
            }
        }
    }

    private func scheduleReconnect() {
        guard isRunning else { return }
        // Timer must be scheduled on the main run loop; this method is called
        // from URLSession completion handlers running on a background queue
        // with no active run loop, where a Timer would never fire.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.reconnectTimer?.invalidate()
            self.reconnectTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                guard let self = self, self.isRunning else { return }
                self.webSocketTask?.cancel(with: .goingAway, reason: nil)
                self.webSocketTask = nil
                self.urlSession?.invalidateAndCancel()
                self.urlSession = nil
                self.connect()
            }
        }
    }

    private func handleMessage(_ text: String) {
        guard let outer = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return }
        guard (outer["op"] as? String) == "publish" else { return }
        guard let msg = outer["msg"] as? [String: Any],
              let dataStr = msg["data"] as? String else { return }
        guard let inner = try? JSONSerialization.jsonObject(with: Data(dataStr.utf8)) as? [String: Any] else { return }
        guard let seq = inner["seq"] as? Int,
              let event = inner["event"] as? String,
              let ts = inner["timestamp_local"] as? String else { return }
        let session = inner["session"] as? String
        DispatchQueue.main.async {
            self.callback?(SyncEvent(seq: seq, event: event, robotTsIso: ts,
                                     session: session))
        }
    }
}

final class ImageStreamClient: NSObject, ObservableObject, RosFrameDelegate, URLSessionWebSocketDelegate {
    @Published var rosBridgeHost: String = RosBridgeDefaults.savedOrCurrentHost()
    private let rosBridgePort: UInt16 = 9090
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var reconnectTimer: Timer?
    private var isRunning = false
    private var isConnected = false
    private let colorImageTopic = "/camera_person/color/image_raw/compressed"
    private let depthImageTopic = "/camera_person/depth/image_raw/compressed"
    private let publishQueue = DispatchQueue(label: "image.publish.queue", qos: .userInitiated)
    private let publishStateLock = NSLock()
    /// True from the moment a frame starts encoding until the last websocket
    /// send it produced has actually been written to the socket. While it is
    /// set, incoming camera frames are dropped instead of queued: URLSession's
    /// send queue is unbounded, so without this a WiFi stall makes base64 JPEG
    /// and zlib depth payloads pile up in memory until iOS jetsams the app.
    private var isPublishingFrame = false
    private var pendingSends = 0
    private var frameEncodingDone = true
    /// Bumped by `resetPublishGate()` so completions from a torn-down socket
    /// cannot decrement the counter belonging to a later frame.
    private var publishGeneration = 0
    private var droppedFrameCount = 0
    private var lastDropLogTs: TimeInterval = 0
    private var lastImagePublishTs: TimeInterval = 0
    /// Footprint accounting, because the crashes correlate with the robot being
    /// on the network rather than with anything the app is asked to do: with
    /// the dog connected nearly every session died, and the one recorded
    /// without it survived 94 s.
    ///
    /// The gate below drops frames while a send is in flight, which is meant to
    /// stop payloads accumulating. But URLSession calls the send completion
    /// when the message reaches the transport, not when it reaches the wire, so
    /// a congested link releases the gate early and the backlog moves into
    /// URLSession's own buffers where nothing here can see it. phys_footprint
    /// is what jetsam measures, so it is what this prints.
    private var lastFootprintLogTs: TimeInterval = 0
    private var peakPendingSends = 0
    /// When the current gated frame claimed the gate, and how long it may hold
    /// it before being written off.
    ///
    /// The gate has three ways out and all of them need something to arrive:
    /// finishSend needs URLSession's completion, markFrameEncodingDone needs
    /// pendingSends to reach zero, resetPublishGate needs a reconnect. A send
    /// whose completion never comes therefore closes the gate until URLSession
    /// gives up on its own. dataset_session_20260829_130658 shows what that
    /// costs: colour stopped for 19.5 s at t=170 and points for 21.3 s, while
    /// frame_meta -- published on a different socket with no gate -- did not
    /// miss a single one of its 1287 messages. Nothing was wrong with the
    /// network; this gate was shut.
    private var publishGateClaimedTs: TimeInterval = 0
    private let publishGateDeadline: TimeInterval = 2.0
    /// 10 Hz, to match the lidar on the robot rather than to chase a number
    /// the link cannot hold.
    ///
    /// At 15 the median interval that actually arrived was 97 ms -- 10.3 Hz --
    /// so the target was unreachable and the gate spent the session thrashing:
    /// dataset_session_20260829_134921 delivered 2331 colour frames against
    /// 3796 asked for, 61 %, in 74 separate holes. Asking for what the link
    /// sustains trades a high ragged rate for a lower even one, and an even
    /// one is what pairs against a 10 Hz sweep.
    private let imagePublishInterval: TimeInterval = 1.0 / 10.0 // 10 Hz

    /// Long-edge width the color frame is downscaled to before JPEG encoding.
    ///
    /// The capture format is 1920x1440 (picked in CameraManager for LiDAR depth
    /// support), which at quality 0.55 produces ~500 KB of JPEG — ~680 KB once
    /// base64'd into the rosbridge JSON, or ~11 MB/s at 15 Hz. That is far more
    /// than WiFi carries, so frames back up and the rate collapses to 4-9 Hz.
    ///
    /// This stream is the online preview only; `LocalVideoRecorder` keeps the
    /// full-resolution archival copy. 640 wide costs ~75 KB/frame (~1.1 MB/s at
    /// 15 Hz) and comfortably out-resolves the 320x240 depth map.
    ///
    /// Set to 0 to publish at native capture resolution.
    /// NOTE: downscaling scales the camera intrinsics by the same factor —
    /// anything doing geometry with these images must account for it. The JPEG
    /// header carries the true published dimensions.
    @Published var publishMaxWidth: CGFloat = 640
    @Published var jpegQuality: CGFloat = 0.55

    private static let ciContext = CIContext(options: nil)

    func start() {
        isRunning = true
        connect()
    }

    func stop() {
        isRunning = false
        isConnected = false
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        resetPublishGate()
    }

    private func connect() {
        guard isRunning else { return }
        isConnected = false
        resetPublishGate()
        let urlString = "ws://\(rosBridgeHost):\(rosBridgePort)"
        guard let url = URL(string: urlString) else { return }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue())
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()
        receiveLoop()
    }

    private func advertiseTopics() {
        sendJson([
            "op": "advertise",
            "topic": colorImageTopic,
            "type": "sensor_msgs/msg/CompressedImage"
        ])
        sendJson([
            "op": "advertise",
            "topic": depthImageTopic,
            "type": "sensor_msgs/msg/CompressedImage"
        ])
    }

    /// Resident footprint in MB, the figure jetsam kills on. -1 if unavailable.
    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return -1 }
        return Double(info.phys_footprint) / 1024.0 / 1024.0
    }

    private func logFootprintIfDue(_ now: TimeInterval) {
        publishStateLock.lock()
        let pending = pendingSends
        if pending > peakPendingSends { peakPendingSends = pending }
        let peak = peakPendingSends
        let due = now - lastFootprintLogTs >= 5.0
        if due {
            lastFootprintLogTs = now
            peakPendingSends = 0
        }
        publishStateLock.unlock()
        if due {
            print(String(format: "🧠 footprint %.1f MB, sends in flight %d (peak %d over 5 s)",
                         footprintMB(), pending, peak))
        }
    }

    func didCaptureFrame(_ sampleBuffer: CMSampleBuffer, depthData: AVDepthData?) {
        guard isConnected else { return }
        let now = Date().timeIntervalSince1970
        logFootprintIfDue(now)
        // Nine tenths of the interval, not all of it. Capture runs at 30 fps,
        // so eligibility is only ever tested at multiples of 33.3 ms, and the
        // frame that lands on 100.0 ms needs only a hair of jitter to read as
        // 99.x and be turned away -- after which the next candidate is 133.3 ms
        // out. The whole stream then settles on every fourth frame instead of
        // every third: dataset_session_20260829_160234 asked for 10 Hz and
        // held a 130 ms median, 7.7 Hz, with the cadence otherwise spotless.
        // The tolerance is smaller than a frame period, so it cannot let two
        // frames through where one was wanted.
        guard now - lastImagePublishTs >= imagePublishInterval * 0.9 else { return }
        guard tryBeginPublishingFrame() else {
            noteDroppedFrame(now)
            return
        }
        lastImagePublishTs = now
        publishQueue.async { [weak self] in
            guard let self = self else { return }
            // Releases the gate once every send this frame started has drained.
            defer { self.markFrameEncodingDone() }
            guard self.isRunning, self.isConnected else { return }
            self.publishColorImage(sampleBuffer: sampleBuffer, phoneTsUnix: now)
            if let depthData = depthData {
                self.publishDepthImage(depthData: depthData, phoneTsUnix: now)
            }
        }
    }

    private func tryBeginPublishingFrame() -> Bool {
        publishStateLock.lock()
        defer { publishStateLock.unlock() }

        let now = Date().timeIntervalSince1970
        if isPublishingFrame {
            guard now - publishGateClaimedTs >= publishGateDeadline else { return false }
            // Bump the generation first: the completions this frame is still
            // owed must not decrement the counter belonging to its successor.
            publishGeneration &+= 1
            pendingSends = 0
            print(String(format: "🖼️ ⚠️ publish gate held %.1f s, forcing it open",
                         now - publishGateClaimedTs))
        }
        isPublishingFrame = true
        frameEncodingDone = false
        publishGateClaimedTs = now
        return true
    }

    /// Called before handing a frame payload to the websocket. Returns the
    /// generation the send belongs to, to be passed back to `finishSend`.
    private func beginSend() -> Int {
        publishStateLock.lock()
        defer { publishStateLock.unlock() }
        pendingSends += 1
        return publishGeneration
    }

    /// Called from the websocket send completion handler.
    private func finishSend(generation: Int) {
        publishStateLock.lock()
        defer { publishStateLock.unlock() }
        guard generation == publishGeneration else { return }
        pendingSends = max(0, pendingSends - 1)
        if frameEncodingDone && pendingSends == 0 {
            isPublishingFrame = false
        }
    }

    private func markFrameEncodingDone() {
        publishStateLock.lock()
        frameEncodingDone = true
        if pendingSends == 0 {
            isPublishingFrame = false
        }
        publishStateLock.unlock()
    }

    /// Clears the gate outright. Used when the socket goes away, so a send
    /// whose completion never arrives cannot wedge publishing permanently.
    private func resetPublishGate() {
        publishStateLock.lock()
        isPublishingFrame = false
        frameEncodingDone = true
        pendingSends = 0
        publishGeneration &+= 1
        publishStateLock.unlock()
    }

    private func noteDroppedFrame(_ now: TimeInterval) {
        publishStateLock.lock()
        droppedFrameCount += 1
        let count = droppedFrameCount
        let shouldLog = now - lastDropLogTs >= 5.0
        if shouldLog {
            lastDropLogTs = now
            droppedFrameCount = 0
        }
        publishStateLock.unlock()

        if shouldLog {
            print("🖼️ ⚠️ dropped \(count) frame(s): websocket send still in flight")
        }
    }

    private func publishColorImage(sampleBuffer: CMSampleBuffer, phoneTsUnix: Double) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // Downscale before encoding, not after: encoding 1920x1440 and then
        // shrinking would burn the CPU we are trying to save.
        let native = ciImage.extent
        var renderRect = native
        let maxWidth = publishMaxWidth
        if maxWidth > 0 && native.width > maxWidth {
            let scale = maxWidth / native.width
            ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            // Render from an explicitly rounded rect: the scaled extent is
            // usually fractional (1440 * 640/1920 = 479.999...), and letting
            // CoreImage round it can yield an off-by-one image size.
            renderRect = CGRect(x: 0, y: 0,
                                width: (native.width * scale).rounded(),
                                height: (native.height * scale).rounded())
        }

        guard let cgImage = Self.ciContext.createCGImage(ciImage, from: renderRect) else { return }
        let image = UIImage(cgImage: cgImage)
        guard let jpegData = image.jpegData(compressionQuality: jpegQuality) else { return }
        let msg: [String: Any] = [
            "header": [
                "stamp": makeRosStamp(fromUnix: phoneTsUnix),
                "frame_id": "person_camera_color_optical_frame"
            ],
            "format": "jpeg",
            "data": jpegData.base64EncodedString()
        ]
        sendJson([
            "op": "publish",
            "topic": colorImageTopic,
            "msg": msg
        ], partOfFrame: true)
    }

    private func publishDepthImage(depthData: AVDepthData, phoneTsUnix: Double) {
        let depth32 = depthData.converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
        let depthMap = depth32.depthDataMap
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else { return }
        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)

        // 16-bit millimetres, not 32-bit metres. Half the bytes before
        // compression, and integers whose neighbours differ by small amounts
        // compress far better than float mantissas whose low bits are noise:
        // the float payload measured 87.4 KB a frame, larger than the colour
        // JPEG beside it at 53.5 KB despite covering a quarter of the pixels.
        //
        // This is also the convention ROS uses for depth, and what the
        // pipeline wanted all along -- sync_writer.py ran every 32FC1 frame
        // through depth * 1000 clipped to [0, 65535] to get here, so the
        // conversion moves to the side that has the pixels rather than the
        // side that has to decompress them first. Its 16uc1 branch already
        // exists.
        //
        // Zero means no reading, matching that same convention: NaN, infinity
        // and anything non-positive land there.
        var depthBytes = Data(count: width * height * 2)
        depthBytes.withUnsafeMutableBytes { rawOut in
            guard let out = rawOut.bindMemory(to: UInt16.self).baseAddress else { return }
            for y in 0..<height {
                let src = baseAddress.advanced(by: y * bytesPerRow)
                                     .assumingMemoryBound(to: Float32.self)
                let dst = out.advanced(by: y * width)
                for x in 0..<width {
                    let metres = src[x]
                    dst[x] = (metres.isFinite && metres > 0)
                        ? UInt16(min(metres * 1000.0, 65535.0))
                        : 0
                }
            }
        }
        guard let compressedDepth = zlibCompress(depthBytes) else { return }
        let msg: [String: Any] = [
            "header": [
                "stamp": makeRosStamp(fromUnix: phoneTsUnix),
                "frame_id": "person_camera_depth_optical_frame"
            ],
            "format": "16UC1;zlib;w=\(width);h=\(height);step=\(width * 2)",
            "data": compressedDepth.base64EncodedString()
        ]
        sendJson([
            "op": "publish",
            "topic": depthImageTopic,
            "msg": msg
        ], partOfFrame: true)
    }

    private func zlibCompress(_ input: Data) -> Data? {
        if input.isEmpty { return Data() }
        let dstCapacity = max(64, input.count + (input.count / 8) + 64)
        var dst = Data(count: dstCapacity)
        let written = input.withUnsafeBytes { srcBuf in
            dst.withUnsafeMutableBytes { dstBuf in
                guard let src = srcBuf.baseAddress?.assumingMemoryBound(to: UInt8.self),
                      let dstPtr = dstBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return 0
                }
                return compression_encode_buffer(
                    dstPtr,
                    dstCapacity,
                    src,
                    input.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        dst.removeSubrange(written..<dst.count)
        return dst
    }

    private func makeRosStamp(fromUnix ts: Double) -> [String: Int] {
        let sec = Int(ts)
        let nsec = Int((ts - Double(sec)) * 1_000_000_000.0)
        return ["sec": sec, "nanosec": max(0, nsec)]
    }

    /// - Parameter partOfFrame: when true the send is tracked by the
    ///   backpressure gate, so the next camera frame is dropped rather than
    ///   queued until this payload has actually reached the socket.
    private func sendJson(_ obj: [String: Any], partOfFrame: Bool = false) {
        guard isConnected, let task = webSocketTask else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        let generation = partOfFrame ? beginSend() : 0
        task.send(.string(text)) { [weak self] err in
            guard let self = self else { return }
            if partOfFrame { self.finishSend(generation: generation) }
            if let err = err {
                print("❌ image send error: \(err)")
                self.scheduleReconnect()
            }
        }
    }

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.receiveLoop()
            case .failure(let err):
                self.isConnected = false
                print("❌ image recv error: \(err)")
                self.scheduleReconnect()
            }
        }
    }

    private func scheduleReconnect() {
        guard isRunning else { return }
        // Timer must be scheduled on the main run loop; this method is called
        // from URLSession completion/delegate callbacks running on a background
        // queue with no active run loop, where a Timer would never fire.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.reconnectTimer?.invalidate()
            self.reconnectTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                guard let self = self, self.isRunning else { return }
                self.isConnected = false
                self.resetPublishGate()
                self.webSocketTask?.cancel(with: .goingAway, reason: nil)
                self.webSocketTask = nil
                self.urlSession?.invalidateAndCancel()
                self.urlSession = nil
                self.connect()
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        isConnected = true
        print("🖼️ image ws connected")
        advertiseTopics()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        isConnected = false
        print("🖼️ image ws closed: \(closeCode.rawValue)")
        scheduleReconnect()
    }
}

final class SensorStreamClient: NSObject, ObservableObject, URLSessionWebSocketDelegate {
    @Published var rosBridgeHost: String = RosBridgeDefaults.savedOrCurrentHost()
    private let rosBridgePort: UInt16 = 9090
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var reconnectTimer: Timer?
    private var isRunning = false
    private var isConnected = false
    private let imuTopic = "/camera_person/imu"
    private let gpsFixTopic = "/camera_person/gps/fix"
    private let gpsVelTopic = "/camera_person/gps/vel"

    func start() {
        isRunning = true
        connect()
    }

    func stop() {
        isRunning = false
        isConnected = false
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
    }

    private func connect() {
        guard isRunning else { return }
        isConnected = false
        let urlString = "ws://\(rosBridgeHost):\(rosBridgePort)"
        guard let url = URL(string: urlString) else { return }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: OperationQueue())
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()
        receiveLoop()
    }

    private func advertiseTopics() {
        sendJson([
            "op": "advertise",
            "topic": imuTopic,
            "type": "sensor_msgs/msg/Imu"
        ])
        sendJson([
            "op": "advertise",
            "topic": gpsFixTopic,
            "type": "sensor_msgs/msg/NavSatFix"
        ])
        sendJson([
            "op": "advertise",
            "topic": gpsVelTopic,
            "type": "geometry_msgs/msg/TwistStamped"
        ])
    }

    func publishImu(phoneTsUnix: Double, ax: Double, ay: Double, az: Double, gx: Double, gy: Double, gz: Double) {
        guard isConnected else { return }
        let stamp = makeRosStamp(fromUnix: phoneTsUnix)
        let msg: [String: Any] = [
            "header": [
                "stamp": stamp,
                "frame_id": "person_phone_imu_frame"
            ],
            "orientation": ["x": 0.0, "y": 0.0, "z": 0.0, "w": 1.0],
            "orientation_covariance": [-1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0],
            "angular_velocity": ["x": gx, "y": gy, "z": gz],
            "angular_velocity_covariance": [0.02, 0.0, 0.0, 0.0, 0.02, 0.0, 0.0, 0.0, 0.02],
            "linear_acceleration": ["x": ax, "y": ay, "z": az],
            "linear_acceleration_covariance": [0.04, 0.0, 0.0, 0.0, 0.04, 0.0, 0.0, 0.0, 0.04]
        ]
        sendJson([
            "op": "publish",
            "topic": imuTopic,
            "msg": msg
        ])
    }

    func publishGps(phoneTsUnix: Double, lat: Double, lon: Double, altM: Double,
                    speedMps: Double, headingDeg: Double,
                    hAccM: Double, vAccM: Double) {
        guard isConnected else { return }
        let stamp = makeRosStamp(fromUnix: phoneTsUnix)
        let headingRad = headingDeg * .pi / 180.0
        let vx = speedMps * sin(headingRad)
        let vy = speedMps * cos(headingRad)

        // Real GPS accuracy from CoreLocation (meters, 1-sigma). Negative means
        // invalid -> report UNKNOWN covariance instead of a fake fixed value.
        let hValid = hAccM > 0
        let vValid = vAccM > 0
        let hVar = hValid ? hAccM * hAccM : 0.0
        let vVar = vValid ? vAccM * vAccM : (hValid ? hVar : 0.0)
        // NavSatFix: 0=UNKNOWN, 2=DIAGONAL_KNOWN
        let covType = hValid ? 2 : 0

        sendJson([
            "op": "publish",
            "topic": gpsFixTopic,
            "msg": [
                "header": [
                    "stamp": stamp,
                    "frame_id": "person_gps_frame"
                ],
                "status": [
                    "status": 0,
                    "service": 1
                ],
                "latitude": lat,
                "longitude": lon,
                "altitude": altM,
                "position_covariance": [hVar, 0.0, 0.0, 0.0, hVar, 0.0, 0.0, 0.0, vVar],
                "position_covariance_type": covType
            ]
        ])
        sendJson([
            "op": "publish",
            "topic": gpsVelTopic,
            "msg": [
                "header": [
                    "stamp": stamp,
                    "frame_id": "person_gps_frame"
                ],
                "twist": [
                    "linear": ["x": vx, "y": vy, "z": 0.0],
                    "angular": ["x": 0.0, "y": 0.0, "z": 0.0]
                ]
            ]
        ])
    }

    private func makeRosStamp(fromUnix ts: Double) -> [String: Int] {
        let sec = Int(ts)
        let nsec = Int((ts - Double(sec)) * 1_000_000_000.0)
        return ["sec": sec, "nanosec": max(0, nsec)]
    }

    private func sendJson(_ obj: [String: Any]) {
        guard isConnected, let task = webSocketTask else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { err in
            if let err = err {
                print("❌ sensor send error: \(err)")
                self.scheduleReconnect()
            }
        }
    }

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success:
                self.receiveLoop()
            case .failure(let err):
                self.isConnected = false
                print("❌ sensor recv error: \(err)")
                self.scheduleReconnect()
            }
        }
    }

    private func scheduleReconnect() {
        guard isRunning else { return }
        // Timer must be scheduled on the main run loop; this method is called
        // from URLSession completion/delegate callbacks running on a background
        // queue with no active run loop, where a Timer would never fire.
        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.isRunning else { return }
            self.reconnectTimer?.invalidate()
            self.reconnectTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                guard let self = self, self.isRunning else { return }
                self.isConnected = false
                self.webSocketTask?.cancel(with: .goingAway, reason: nil)
                self.webSocketTask = nil
                self.urlSession?.invalidateAndCancel()
                self.urlSession = nil
                self.connect()
            }
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        isConnected = true
        print("🧭 sensor ws connected")
        advertiseTopics()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        isConnected = false
        print("🧭 sensor ws closed: \(closeCode.rawValue)")
        scheduleReconnect()
    }
}

private extension DateFormatter {
    static let sessionFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd_HHmmss"
        return f
    }()
}

// MARK: - Sensor Data Panel
struct SensorDataPanel: View {
    @ObservedObject var sensorManager: SensorDataManager
    let closeAction: () -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(red: 0.035, green: 0.047, blue: 0.063)
                    .ignoresSafeArea(.all)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 12) {
                        header
                            .padding(.top, geometry.safeAreaInsets.top + 6)

                        sensorSection(
                            title: "IMU",
                            icon: "gyroscope",
                            rows: [
                                sensorRow("Acceleration X", format(sensorManager.acceleration.x), "g"),
                                sensorRow("Acceleration Y", format(sensorManager.acceleration.y), "g"),
                                sensorRow("Acceleration Z", format(sensorManager.acceleration.z), "g"),
                                sensorRow("Gyro X", format(sensorManager.rotationRate.x), "rad/s"),
                                sensorRow("Gyro Y", format(sensorManager.rotationRate.y), "rad/s"),
                                sensorRow("Gyro Z", format(sensorManager.rotationRate.z), "rad/s"),
                                sensorRow("Roll", degrees(sensorManager.attitude.x), "deg"),
                                sensorRow("Pitch", degrees(sensorManager.attitude.y), "deg"),
                                sensorRow("Yaw", degrees(sensorManager.attitude.z), "deg")
                            ]
                        )

                        sensorSection(
                            title: "GPS",
                            icon: "location.fill",
                            rows: [
                                sensorRow("Latitude", coordinate(sensorManager.latitude), ""),
                                sensorRow("Longitude", coordinate(sensorManager.longitude), ""),
                                sensorRow("Altitude", optional(sensorManager.altitude), "m"),
                                sensorRow("Horizontal Accuracy", optional(sensorManager.horizontalAccuracy), "m"),
                                sensorRow("Vertical Accuracy", optional(sensorManager.verticalAccuracy), "m"),
                                sensorRow("Timestamp", timestamp(sensorManager.locationTimestamp), "")
                            ]
                        )

                        sensorSection(
                            title: "GNSS",
                            icon: "antenna.radiowaves.left.and.right",
                            rows: [
                                sensorRow("Location Service", sensorManager.isLocationServiceEnabled ? "Enabled" : "Disabled", ""),
                                sensorRow("Authorization", authorization(sensorManager.authorizationStatus), ""),
                                sensorRow("Magnetic Heading", optional(sensorManager.magneticHeading), "deg"),
                                sensorRow("True Heading", optional(sensorManager.trueHeading), "deg"),
                                sensorRow("Simulated Source", boolean(sensorManager.isSimulatedBySoftware), ""),
                                sensorRow("Accessory Source", boolean(sensorManager.isProducedByAccessory), "")
                            ]
                        )

                        sensorSection(
                            title: "GPS Motion",
                            icon: "speedometer",
                            rows: [
                                sensorRow("Speed", optional(sensorManager.speed), "m/s"),
                                sensorRow("Speed", speedKmh(sensorManager.speed), "km/h"),
                                sensorRow("Speed Accuracy", optional(sensorManager.speedAccuracy), "m/s"),
                                sensorRow("Course", optional(sensorManager.course), "deg"),
                                sensorRow("Course Accuracy", optional(sensorManager.courseAccuracy), "deg"),
                                sensorRow("Vertical Speed", optional(sensorManager.verticalSpeed), "m/s")
                            ]
                        )

                        Color.clear.frame(height: geometry.safeAreaInsets.bottom + 92)
                    }
                    .padding(.horizontal, 20)
                    .frame(width: geometry.size.width)
                    .frame(minHeight: geometry.size.height)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .background(Color(red: 0.035, green: 0.047, blue: 0.063))
            .ignoresSafeArea(.all)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sensor Data")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.white)
                Text("IMU / GPS / GNSS")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
            }

            Spacer()
        }
    }

    private func sensorSection(title: String, icon: String, rows: [SensorDisplayRow]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Color(red: 0.22, green: 0.52, blue: 1.0))
                    .frame(width: 28, height: 28)
                    .background(Color(red: 0.22, green: 0.52, blue: 1.0).opacity(0.22))
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundColor(.white.opacity(0.92))
            }

            VStack(spacing: 8) {
                ForEach(rows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.52))
                        Spacer(minLength: 12)
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(row.value)
                                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                .foregroundColor(.white.opacity(0.88))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                            if !row.unit.isEmpty {
                                Text(row.unit)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(.white.opacity(0.4))
                            }
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [
                    Color.white.opacity(0.09),
                    Color.white.opacity(0.045)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.09), lineWidth: 1)
        )
    }

    private func sensorRow(_ label: String, _ value: String, _ unit: String) -> SensorDisplayRow {
        SensorDisplayRow(label: label, value: value, unit: unit)
    }

    private func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }

    private func optional(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.3f", value)
    }

    private func coordinate(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.7f", value)
    }

    private func degrees(_ radians: Double) -> String {
        String(format: "%.2f", radians * 180 / .pi)
    }

    private func speedKmh(_ value: Double?) -> String {
        guard let value else { return "--" }
        return String(format: "%.2f", value * 3.6)
    }

    private func timestamp(_ date: Date?) -> String {
        guard let date else { return "--" }
        return date.formatted(date: .omitted, time: .standard)
    }

    private func boolean(_ value: Bool?) -> String {
        guard let value else { return "--" }
        return value ? "Yes" : "No"
    }

    private func authorization(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "Not Determined"
        case .restricted:
            return "Restricted"
        case .denied:
            return "Denied"
        case .authorizedAlways:
            return "Always"
        case .authorizedWhenInUse:
            return "When In Use"
        @unknown default:
            return "Unknown"
        }
    }
}

struct SensorDisplayRow: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let unit: String
}

// MARK: - Camera Preview
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .clear

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill

        view.layer.addSublayer(previewLayer)
        view.previewLayer = previewLayer

        // Set video orientation after adding layer (connection becomes available)
        DispatchQueue.main.async {
            if let connection = previewLayer.connection {
                if #available(iOS 17.0, *) {
                    connection.videoRotationAngle = 90
                    print("📱 Preview rotation angle set to 90°")
                } else {
                    connection.videoOrientation = .portrait
                    print("📱 Preview orientation set to portrait")
                }
            }
        }

        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
    }

    class PreviewUIView: UIView {
        var previewLayer: AVCaptureVideoPreviewLayer?

        override func layoutSubviews() {
            super.layoutSubviews()
            previewLayer?.frame = bounds
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
#Preview {
    ContentView()
}
#endif
