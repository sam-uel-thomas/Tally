import Foundation
import SwiftUI
import IOKit
import UserNotifications
import AppKit
import ServiceManagement

// MARK: - Theme

enum AppTheme: String, Codable, CaseIterable {
    case system, light, dark
}

extension Color {
    static let tallyDark = Color(red: 42/255, green: 37/255, blue: 41/255)
    static let tallyLight = Color(red: 243/255, green: 240/255, blue: 231/255)
}

struct TallyTheme: ViewModifier {
    @ObservedObject var manager: TrackerManager
    @Environment(\.colorScheme) var systemColorScheme
    
    var colorScheme: ColorScheme {
        switch manager.appTheme {
        case .system: return systemColorScheme
        case .light: return .light
        case .dark: return .dark
        }
    }
    
    var background: Color { colorScheme == .dark ? .tallyDark : .tallyLight }
    var foreground: Color { colorScheme == .dark ? .tallyLight : .tallyDark }
    var secondaryBackground: Color { foreground.opacity(0.08) }
    var tertiaryBackground: Color { foreground.opacity(0.04) }
    
    func body(content: Content) -> some View {
        content
            .background(background)
            .foregroundStyle(foreground)
            .preferredColorScheme(colorScheme)
    }
}

struct TallyButtonStyle: ButtonStyle {
    @State private var isHovering = false
    
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : (isHovering ? 0.8 : 1.0))
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.1)) {
                    isHovering = hovering
                }
            }
    }
}

extension View {
    func tallyTheme(manager: TrackerManager) -> some View { self.modifier(TallyTheme(manager: manager)) }
}

// MARK: - Models

struct Project: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    
    init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

struct Session: Identifiable, Codable, Equatable {
    let id: UUID
    let projectId: UUID
    let startTime: Date
    var endTime: Date?
    
    var duration: TimeInterval {
        let end = endTime ?? Date()
        return max(0, end.timeIntervalSince(startTime))
    }
    
    init(id: UUID = UUID(), projectId: UUID, startTime: Date = Date(), endTime: Date? = nil) {
        self.id = id
        self.projectId = projectId
        self.startTime = startTime
        self.endTime = endTime
    }
}

// MARK: - Tracker Manager

final class TrackerManager: ObservableObject {
    @Published var projects: [Project] = []
    @Published var sessions: [Session] = []
    @Published var activeSession: Session?
    @Published var selectedProjectId: UUID?
    @Published var launchAtLogin: Bool = false
    @Published var idleThreshold: TimeInterval = 300 // default 5 mins
    @Published var appTheme: AppTheme = .system
    
    private var timer: Timer?
    private var heartbeatTimer: Timer?
    private var idleCheckTimer: Timer?
    
    private let heartbeatInterval: TimeInterval = 30
    private let gapThreshold: TimeInterval = 300 
    
    private let projectsKey = "tally_projects"
    private let sessionsKey = "tally_sessions"
    private let activeSessionKey = "tally_active_session"
    private let lastHeartbeatKey = "tally_last_heartbeat"
    private let idleThresholdKey = "tally_idle_threshold"
    private let appThemeKey = "tally_app_theme"
    
    init() {
        loadData()
        refreshLaunchStatus()
        requestNotificationPermission()
        checkForInterruptedSession()
        startIdleCheck()
        if activeSession != nil { startTimers() }
    }
    
    func refreshLaunchStatus() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }
    
    func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
            }
            refreshLaunchStatus()
        } catch {
            print("Failed to update launch status: \(error)")
        }
    }
    
    func setIdleThreshold(_ minutes: Double) {
        idleThreshold = minutes * 60
        UserDefaults.standard.set(idleThreshold, forKey: idleThresholdKey)
    }
    
    func setTheme(_ theme: AppTheme) {
        appTheme = theme
        UserDefaults.standard.set(theme.rawValue, forKey: appThemeKey)
    }
    
    func startSession(for projectId: UUID) {
        if activeSession != nil { stopSession() }
        activeSession = Session(projectId: projectId)
        selectedProjectId = projectId
        saveActiveSession()
        startTimers()
        updateHeartbeat()
    }
    
    func stopSession() {
        guard var session = activeSession else { return }
        session.endTime = Date()
        sessions.insert(session, at: 0)
        activeSession = nil
        stopTimers()
        clearHeartbeat()
        saveData()
    }
    
    func toggleSession(for projectId: UUID) {
        if activeSession?.projectId == projectId {
            stopSession()
        } else {
            startSession(for: projectId)
        }
    }
    
    func addProject(name: String) {
        projects.append(Project(name: name))
        saveData()
    }
    
    func deleteProject(id: UUID) {
        if activeSession?.projectId == id {
            activeSession = nil
            stopTimers()
            clearActiveSession()
        }
        projects.removeAll { $0.id == id }
        sessions.removeAll { $0.projectId == id }
        saveData()
    }
    
    func resetProjectTime(id: UUID) {
        if activeSession?.projectId == id {
            activeSession = nil
            stopTimers()
            clearActiveSession()
        }
        sessions.removeAll { $0.projectId == id }
        saveData()
    }
    
    func deleteSession(id: UUID) {
        sessions.removeAll { $0.id == id }
        saveData()
    }
    
    func deleteAllSessions() {
        sessions.removeAll()
        saveData()
    }
    
    private func saveData() {
        if let encoded = try? JSONEncoder().encode(projects) { UserDefaults.standard.set(encoded, forKey: projectsKey) }
        if let encoded = try? JSONEncoder().encode(sessions) { UserDefaults.standard.set(encoded, forKey: sessionsKey) }
    }
    
    private func loadData() {
        if let data = UserDefaults.standard.data(forKey: projectsKey), let decoded = try? JSONDecoder().decode([Project].self, from: data) { projects = decoded }
        if let data = UserDefaults.standard.data(forKey: sessionsKey), let decoded = try? JSONDecoder().decode([Session].self, from: data) { sessions = decoded }
        if let data = UserDefaults.standard.data(forKey: activeSessionKey), let decoded = try? JSONDecoder().decode(Session.self, from: data) {
            activeSession = decoded
            selectedProjectId = decoded.projectId
        }
        let savedIdle = UserDefaults.standard.double(forKey: idleThresholdKey)
        if savedIdle > 0 {
            idleThreshold = savedIdle
        }
        if let savedTheme = UserDefaults.standard.string(forKey: appThemeKey), let theme = AppTheme(rawValue: savedTheme) {
            appTheme = theme
        }
    }
    
    private func saveActiveSession() {
        if let encoded = try? JSONEncoder().encode(activeSession) { UserDefaults.standard.set(encoded, forKey: activeSessionKey) }
    }
    
    private func clearActiveSession() { UserDefaults.standard.removeObject(forKey: activeSessionKey) }
    
    private func startTimers() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.objectWillChange.send() }
        heartbeatTimer = Timer.scheduledTimer(withTimeInterval: heartbeatInterval, repeats: true) { [weak self] _ in self?.updateHeartbeat() }
    }
    
    private func stopTimers() { timer?.invalidate(); heartbeatTimer?.invalidate(); timer = nil; heartbeatTimer = nil }
    private func updateHeartbeat() { UserDefaults.standard.set(Date(), forKey: lastHeartbeatKey) }
    private func clearHeartbeat() { UserDefaults.standard.removeObject(forKey: lastHeartbeatKey); clearActiveSession() }
    
    private func checkForInterruptedSession() {
        guard let lastHeartbeat = UserDefaults.standard.object(forKey: lastHeartbeatKey) as? Date, let active = activeSession else { return }
        if Date().timeIntervalSince(lastHeartbeat) > gapThreshold {
            var concluded = active
            concluded.endTime = lastHeartbeat
            sessions.insert(concluded, at: 0)
            activeSession = nil
            clearHeartbeat()
            saveData()
            sendNotification(title: "Session Concluded", body: "Tally recovered a session.")
        }
    }
    
    private func startIdleCheck() { idleCheckTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.checkIdleTime() } }
    
    private func checkIdleTime() {
        guard activeSession != nil else { return }
        if let idleSeconds = getSystemIdleTime(), idleSeconds > idleThreshold {
            sendNotification(title: "Idle Detected", body: "Paused due to inactivity.")
            stopSession()
        }
    }
    
    private func getSystemIdleTime() -> Double? {
        var iterator: io_iterator_t = 0
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"), &iterator)
        guard result == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        let entry = IOIteratorNext(iterator)
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        var unmanagedDict: Unmanaged<CFMutableDictionary>?
        if IORegistryEntryCreateCFProperties(entry, &unmanagedDict, kCFAllocatorDefault, 0) == KERN_SUCCESS,
           let dict = unmanagedDict?.takeRetainedValue() as? [String: Any],
           let idleTimeNano = dict["HIDIdleTime"] as? Int64 {
            return Double(idleTimeNano) / Double(NSEC_PER_SEC)
        }
        return nil
    }
    
    func projectName(for id: UUID) -> String { projects.first(where: { $0.id == id })?.name ?? "Unknown" }
    
    func totalTime(for projectId: UUID) -> TimeInterval {
        let completedTotal = sessions
            .filter { $0.projectId == projectId }
            .reduce(0) { $0 + $1.duration }
        if let active = activeSession, active.projectId == projectId { return completedTotal + active.duration }
        return completedTotal
    }

    func formatDuration(_ duration: TimeInterval) -> String {
        let h = Int(duration) / 3600, m = (Int(duration) % 3600) / 60, s = Int(duration) % 60
        return String(format: "%02d:%02d:%02d", h, m, s)
    }
    
    func copyToClipboard(session: Session) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(formatDuration(session.duration), forType: .string)
    }
    
    private func requestNotificationPermission() { UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in } }
    private func sendNotification(title: String, body: String) {
        let content = UNMutableNotificationContent(); content.title = title; content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}

// MARK: - Components

struct TallyFooter: View {
    var body: some View {
        HStack {
            QuitButton()
            Spacer()
            Text("v1.0.0").font(.caption2).opacity(0.4)
        }.padding(.horizontal).padding(.vertical, 8)
    }
}

struct QuitButton: View {
    @State private var isHovering = false
    
    var body: some View {
        Button(action: { NSApplication.shared.terminate(nil) }) {
            Text("Quit")
                .font(.caption)
                .opacity(0.6)
                .underline(isHovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.1)) {
                isHovering = hovering
            }
        }
    }
}

// MARK: - Views

struct RootView: View {
    @ObservedObject var manager: TrackerManager
    
    var body: some View {
        NavigationStack {
            MainView(manager: manager)
        }
        .frame(width: 320)
        .tallyTheme(manager: manager)
    }
}

struct MainView: View {
    @ObservedObject var manager: TrackerManager
    @State private var newProjectName = ""
    
    var theme: TallyTheme { TallyTheme(manager: manager) }
    
    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(manager.foreground(opacity: 0.1))
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    projectSection
                }
                .padding()
            }
            Divider().overlay(manager.foreground(opacity: 0.1))
            TallyFooter()
        }
        .frame(height: 320)
        .tallyTheme(manager: manager)
    }
    
    private var header: some View {
        HStack {
            Image(systemName: "timer").font(.title2)
            Text("Tally").font(.headline)
            Spacer()
            if let active = manager.activeSession {
                Text(manager.formatDuration(manager.totalTime(for: active.projectId))).monospaced().bold()
            }
            NavigationLink(destination: SettingsView(manager: manager)) {
                Image(systemName: "gearshape").font(.body)
            }.buttonStyle(TallyButtonStyle()).padding(.leading, 8)
        }.padding()
    }
    
    private var projectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Projects", systemImage: "briefcase").font(.caption).opacity(0.6)
            ForEach(manager.projects) { project in
                HStack {
                    Text(project.name).fontWeight(manager.activeSession?.projectId == project.id ? .bold : .regular)
                    Spacer()
                    Text(manager.formatDuration(manager.totalTime(for: project.id))).monospaced().font(.caption).opacity(0.6)
                    Button(action: { manager.toggleSession(for: project.id) }) {
                        Image(systemName: manager.activeSession?.projectId == project.id ? "stop.fill" : "play.fill")
                    }.buttonStyle(TallyButtonStyle())
                }.padding(8).background(manager.foreground(opacity: 0.05)).cornerRadius(6)
            }
            
            HStack {
                TextField("New Project", text: $newProjectName)
                    .textFieldStyle(.plain)
                    .onSubmit { if !newProjectName.isEmpty { manager.addProject(name: newProjectName); newProjectName = "" } }
                
                Spacer()
                
                Button(action: { if !newProjectName.isEmpty { manager.addProject(name: newProjectName); newProjectName = "" } }) {
                    Image(systemName: "plus")
                }
                .disabled(newProjectName.isEmpty)
                .buttonStyle(TallyButtonStyle())
            }
            .padding(8)
            .background(manager.foreground(opacity: 0.05))
            .cornerRadius(6)
        }
    }
}

struct SettingsView: View {
    @ObservedObject var manager: TrackerManager
    @Environment(\.dismiss) var dismiss
    
    @State private var projectToReset: Project?
    @State private var projectToDelete: Project?
    
    let timeoutOptions: [Double] = [1, 2, 5, 10, 15, 30]
    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack {
                    Text("Settings").font(.headline)
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                    }.buttonStyle(TallyButtonStyle())
                }.padding()
                
                Divider().overlay(manager.foreground(opacity: 0.1))
                
                ScrollView {
                    VStack(spacing: 16) {
                        // Appearance Selection
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Appearance", systemImage: "paintbrush")
                                .font(.caption).opacity(0.6).padding(.horizontal, 4)
                            
                            HStack(spacing: 8) {
                                ForEach(AppTheme.allCases, id: \.self) { theme in
                                    Button(action: { manager.setTheme(theme) }) {
                                        Text(theme.rawValue.capitalized)
                                            .font(.caption2)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 6)
                                            .background(manager.appTheme == theme ? manager.foreground(opacity: 0.15) : manager.foreground(opacity: 0.05))
                                            .cornerRadius(6)
                                    }.buttonStyle(.plain)
                                }
                            }
                            .padding(4)
                        }

                        // Launch at Login Toggle
                        Button(action: { manager.toggleLaunchAtLogin() }) {
                            HStack {
                                Label("Open on Launch", systemImage: manager.launchAtLogin ? "checkmark.circle.fill" : "circle")
                                Spacer()
                                Text(manager.launchAtLogin ? "On" : "Off").font(.caption).opacity(0.6)
                            }
                            .padding(12)
                            .background(manager.foreground(opacity: 0.05))
                            .cornerRadius(8)
                        }.buttonStyle(TallyButtonStyle())

                        // Timeout Cooldown Selection
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Idle Timeout", systemImage: "clock.badge.exclamationmark")
                                .font(.caption).opacity(0.6).padding(.horizontal, 4)
                            
                            HStack(spacing: 8) {
                                ForEach(timeoutOptions, id: \.self) { mins in
                                    Button(action: { manager.setIdleThreshold(mins) }) {
                                        Text("\(Int(mins))m")
                                            .font(.caption2)
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 6)
                                            .background(manager.idleThreshold == mins * 60 ? manager.foreground(opacity: 0.15) : manager.foreground(opacity: 0.05))
                                            .cornerRadius(6)
                                    }.buttonStyle(.plain)
                                }
                            }
                            .padding(4)
                        }

                        NavigationLink(destination: HistoryView(manager: manager)) {
                            HStack {
                                Label("View Session History", systemImage: "clock.arrow.circlepath")
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                            }
                            .padding(12)
                            .background(manager.foreground(opacity: 0.05))
                            .cornerRadius(8)
                        }.buttonStyle(TallyButtonStyle())
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Manage Projects").font(.caption).opacity(0.6).padding(.horizontal, 4)
                            
                            ForEach(manager.projects) { project in
                                HStack {
                                    Text(project.name).font(.subheadline)
                                    Spacer()
                                    HStack(spacing: 16) {
                                        Button(action: { projectToReset = project }) {
                                            Image(systemName: "arrow.counterclockwise")
                                        }.buttonStyle(TallyButtonStyle())
                                        
                                        Button(action: { projectToDelete = project }) {
                                            Image(systemName: "trash")
                                        }.buttonStyle(TallyButtonStyle())
                                    }
                                }
                                .padding(10)
                                .background(manager.foreground(opacity: 0.05))
                                .cornerRadius(8)
                            }
                        }
                    }.padding()
                }
                
                Divider().overlay(manager.foreground(opacity: 0.1))
                TallyFooter()
            }
            
            // Custom Confirmation Overlays
            if projectToReset != nil || projectToDelete != nil {
                Color.black.opacity(0.4)
                    .edgesIgnoringSafeArea(.all)
                
                VStack(spacing: 16) {
                    Text(projectToReset != nil ? "Reset Project Time?" : "Delete Project?")
                        .font(.headline)
                    
                    Text(projectToReset != nil ? 
                         "Are you sure you want to reset all recorded time for '\(projectToReset?.name ?? "")'? This cannot be undone." :
                         "Are you sure you want to delete '\(projectToDelete?.name ?? "")'? This will remove all history and cannot be undone.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .opacity(0.6)
                    
                    HStack(spacing: 20) {
                        Button("Cancel") {
                            withAnimation {
                                projectToReset = nil
                                projectToDelete = nil
                            }
                        }.buttonStyle(TallyButtonStyle())
                        
                        Button(projectToReset != nil ? "Reset" : "Delete") {
                            withAnimation {
                                if let p = projectToReset {
                                    manager.resetProjectTime(id: p.id)
                                    projectToReset = nil
                                } else if let p = projectToDelete {
                                    manager.deleteProject(id: p.id)
                                    projectToDelete = nil
                                }
                            }
                        }.buttonStyle(TallyButtonStyle()).fontWeight(.bold)
                    }
                }
                .padding()
                .frame(width: 260)
                .tallyTheme(manager: manager)
                .cornerRadius(12)
                .shadow(radius: 10)
            }
        }
        .frame(width: 320, height: 400)
        .tallyTheme(manager: manager)
        .navigationBarBackButtonHidden(true)
        .onAppear {
            manager.refreshLaunchStatus()
        }
    }
}

struct HistoryView: View {
    @ObservedObject var manager: TrackerManager
    @Environment(\.dismiss) var dismiss
    
    @State private var sessionToDelete: Session?
    @State private var showDeleteAllConfirmation = false
    
    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                HStack {
                    Text("Session History").font(.headline)
                    Spacer()
                    Button(action: { dismiss() }) {
                        Image(systemName: "chevron.left")
                    }.buttonStyle(TallyButtonStyle())
                }.padding()
                
                Divider().overlay(manager.foreground(opacity: 0.1))
                
                ScrollView {
                    VStack(spacing: 8) {
                        if manager.sessions.isEmpty {
                            Text("No recorded sessions.").opacity(0.6).padding()
                        } else {
                            // Delete All Button
                            Button(action: { showDeleteAllConfirmation = true }) {
                                HStack {
                                    Label("Delete All History", systemImage: "trash")
                                    Spacer()
                                }
                                .padding(10)
                                .background(manager.foreground(opacity: 0.05))
                                .cornerRadius(8)
                            }.buttonStyle(TallyButtonStyle())
                            .padding(.bottom, 8)
                            
                            ForEach(manager.sessions) { session in
                                HStack {
                                    VStack(alignment: .leading) {
                                        Text(manager.projectName(for: session.projectId)).font(.subheadline).fontWeight(.medium)
                                        Text(session.startTime.formatted(date: .omitted, time: .shortened)).font(.caption2).opacity(0.6)
                                    }
                                    Spacer()
                                    HStack(spacing: 8) {
                                        Text(manager.formatDuration(session.duration)).monospaced().onTapGesture { manager.copyToClipboard(session: session) }
                                        
                                        Divider().frame(height: 12).padding(.horizontal, 4)
                                        
                                        Button(action: { sessionToDelete = session }) {
                                            Image(systemName: "trash").font(.caption)
                                        }.buttonStyle(TallyButtonStyle())
                                    }
                                }.padding(8).background(manager.foreground(opacity: 0.05)).cornerRadius(6)
                            }
                        }
                    }.padding()
                }
                
                Divider().overlay(manager.foreground(opacity: 0.1))
                TallyFooter()
            }
            
            // Confirmation Overlays
            if sessionToDelete != nil || showDeleteAllConfirmation {
                Color.black.opacity(0.4)
                    .edgesIgnoringSafeArea(.all)
                
                VStack(spacing: 16) {
                    Text(showDeleteAllConfirmation ? "Delete All History?" : "Delete Session?")
                        .font(.headline)
                    
                    Text(showDeleteAllConfirmation ? 
                         "Are you sure you want to clear ALL session history? This cannot be undone." :
                         "Are you sure you want to delete this session? This will update the project total.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .opacity(0.6)
                    
                    HStack(spacing: 20) {
                        Button("Cancel") {
                            withAnimation {
                                sessionToDelete = nil
                                showDeleteAllConfirmation = false
                            }
                        }.buttonStyle(TallyButtonStyle())
                        
                        Button("Delete") {
                            withAnimation {
                                if showDeleteAllConfirmation {
                                    manager.deleteAllSessions()
                                    showDeleteAllConfirmation = false
                                } else if let s = sessionToDelete {
                                    manager.deleteSession(id: s.id)
                                    sessionToDelete = nil
                                }
                            }
                        }.buttonStyle(TallyButtonStyle()).fontWeight(.bold)
                    }
                }
                .padding()
                .frame(width: 260)
                .tallyTheme(manager: manager)
                .cornerRadius(12)
                .shadow(radius: 10)
            }
        }
        .frame(width: 320, height: 400)
        .tallyTheme(manager: manager)
        .navigationBarBackButtonHidden(true)
    }
}

// MARK: - Extension

extension TrackerManager {
    func foreground(opacity: Double = 1.0) -> Color {
        let isDark = (appTheme == .dark) || (appTheme == .system && NSApp.effectiveAppearance.name == .darkAqua)
        let base = isDark ? Color.tallyLight : Color.tallyDark
        return base.opacity(opacity)
    }
}

// MARK: - App

@main
struct TallyApp: App {
    @StateObject private var manager = TrackerManager()
    
    var body: some Scene {
        MenuBarExtra {
            RootView(manager: manager)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "timer")
                if let active = manager.activeSession {
                    Text(manager.formatDuration(manager.totalTime(for: active.projectId))).monospaced()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }
}
