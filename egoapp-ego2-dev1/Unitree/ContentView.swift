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
    @StateObject private var syncClient = SyncEventClient()
    @StateObject private var imageClient = ImageStreamClient()
    @StateObject private var sensorClient = SensorStreamClient()
    @State private var frameIdx: Int = 0
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
            print("✅ Set video and point cloud delegates")
            
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
            sessionLogger.logImu(
                phoneTsUnix: ts,
                ax: sensorManager.acceleration.x,
                ay: sensorManager.acceleration.y,
                az: sensorManager.acceleration.z,
                gx: sensorManager.rotationRate.x,
                gy: sensorManager.rotationRate.y,
                gz: sensorManager.rotationRate.z
            )
            sensorClient.publishImu(
                phoneTsUnix: ts,
                ax: sensorManager.acceleration.x,
                ay: sensorManager.acceleration.y,
                az: sensorManager.acceleration.z,
                gx: sensorManager.rotationRate.x,
                gy: sensorManager.rotationRate.y,
                gz: sensorManager.rotationRate.z
            )
            if let lat = sensorManager.latitude, let lon = sensorManager.longitude {
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
                    headingDeg: sensorManager.course ?? 0.0
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
                TextField("192.168.x.x", text: $rosBridgeIP)
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
    
    private func handleStartStop() {
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
            sessionLogger.endSession()
            syncClient.publishRecordStatus(isRecording: false, reason: "manual_or_sync_stop")
            announceAction("Stopping camera and servers")
        } else {
            print("🔘 >>> STARTING camera, video server, and ROS2 client")
            frameIdx = 0
            sessionLogger.startNewSession()
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
            handleStartStop()
        } else if event.event == "stop_recording" && cameraManager.isSessionRunning {
            handleStartStop()
        }
    }
}

final class SessionLogger: ObservableObject {
    private var sessionDir: URL?
    private let fm = FileManager.default

    func startNewSession() {
        let ts = DateFormatter.sessionFormatter.string(from: Date())
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first!
        let dir = docs.appendingPathComponent("dataset_session_\(ts)", isDirectory: true)
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
        if !fm.fileExists(atPath: f.path) {
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

    private func fmt(_ t: Double) -> String {
        String(format: "%.6f", t)
    }
}

struct SyncEvent {
    let seq: Int
    let event: String
    let robotTsIso: String
}

final class SyncEventClient: ObservableObject {
    @Published var rosBridgeHost: String = "172.20.10.3"
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
        config.timeoutIntervalForRequest = 10
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
        DispatchQueue.main.async {
            self.callback?(SyncEvent(seq: seq, event: event, robotTsIso: ts))
        }
    }
}

final class ImageStreamClient: NSObject, ObservableObject, RosFrameDelegate, URLSessionWebSocketDelegate {
    @Published var rosBridgeHost: String = "172.20.10.3"
    private let rosBridgePort: UInt16 = 9090
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var reconnectTimer: Timer?
    private var isRunning = false
    private var isConnected = false
    private let colorImageTopic = "/camera_person/color/image_raw/compressed"
    private let depthImageTopic = "/camera_person/depth/image_raw/compressed"
    private let publishQueue = DispatchQueue(label: "image.publish.queue", qos: .userInitiated)
    private var lastImagePublishTs: TimeInterval = 0
    private let imagePublishInterval: TimeInterval = 0.2
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
    }
    
    private func connect() {
        guard isRunning else { return }
        isConnected = false
        let urlString = "ws://\(rosBridgeHost):\(rosBridgePort)"
        guard let url = URL(string: urlString) else { return }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
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

    func didCaptureFrame(_ sampleBuffer: CMSampleBuffer, depthData: AVDepthData?) {
        guard isConnected else { return }
        let now = Date().timeIntervalSince1970
        guard now - lastImagePublishTs >= imagePublishInterval else { return }
        lastImagePublishTs = now
        publishQueue.async { [weak self] in
            guard let self = self else { return }
            self.publishColorImage(sampleBuffer: sampleBuffer, phoneTsUnix: now)
            if let depthData = depthData {
                self.publishDepthImage(depthData: depthData, phoneTsUnix: now)
            }
        }
    }

    private func publishColorImage(sampleBuffer: CMSampleBuffer, phoneTsUnix: Double) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = Self.ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
        let image = UIImage(cgImage: cgImage)
        guard let jpegData = image.jpegData(compressionQuality: 0.55) else { return }
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
        ])
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
        var depthBytes = Data(capacity: width * height * 4)
        for y in 0..<height {
            let row = baseAddress.advanced(by: y * bytesPerRow)
            depthBytes.append(row.assumingMemoryBound(to: UInt8.self), count: width * 4)
        }
        guard let compressedDepth = zlibCompress(depthBytes) else { return }
        let msg: [String: Any] = [
            "header": [
                "stamp": makeRosStamp(fromUnix: phoneTsUnix),
                "frame_id": "person_camera_depth_optical_frame"
            ],
            "format": "32FC1;zlib;w=\(width);h=\(height);step=\(width * 4)",
            "data": compressedDepth.base64EncodedString()
        ]
        sendJson([
            "op": "publish",
            "topic": depthImageTopic,
            "msg": msg
        ])
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
    
    private func sendJson(_ obj: [String: Any]) {
        guard isConnected, let task = webSocketTask else { return }
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { err in
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
    @Published var rosBridgeHost: String = "172.20.10.3"
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
        config.timeoutIntervalForRequest = 10
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
    
    func publishGps(phoneTsUnix: Double, lat: Double, lon: Double, altM: Double, speedMps: Double, headingDeg: Double) {
        guard isConnected else { return }
        let stamp = makeRosStamp(fromUnix: phoneTsUnix)
        let headingRad = headingDeg * .pi / 180.0
        let vx = speedMps * sin(headingRad)
        let vy = speedMps * cos(headingRad)
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
                "position_covariance": [9.0, 0.0, 0.0, 0.0, 9.0, 0.0, 0.0, 0.0, 16.0],
                "position_covariance_type": 2
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
