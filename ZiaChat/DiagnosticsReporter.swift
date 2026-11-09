import CryptoKit
import Foundation
import MetricKit
import os
import UIKit

/// Reporta al servidor (Convex `appDiagnostics:report`) por qué se cerró la app.
///
/// Junta dos fuentes:
///
/// 1. **MetricKit**: el sistema entrega, en el siguiente arranque, el crash
///    con su pila (`MXCrashDiagnostic`), los bloqueos y los excesos de CPU; y
///    una vez al día el conteo de salidas por causa (límite de memoria,
///    watchdog, acceso inválido…).
/// 2. **Bitácora de sesión propia**: cada 15 s guarda memoria, CPU, hilos y
///    estado térmico. Si la sesión anterior terminó en primer plano sin
///    cerrarse limpio, al volver a abrir se manda esa bitácora. Cubre lo que
///    MetricKit no detalla (el sistema matando la app por memoria no deja
///    crash) y llega de inmediato, sin esperar al reporte diario.
///
/// Los reportes se guardan en disco y se mandan cuando hay sesión vigente; no
/// incluyen contenido de mensajes.
nonisolated final class DiagnosticsReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = DiagnosticsReporter()

    private static let logger = Logger(subsystem: "authcode.ZiaChat", category: "Diagnostics")
    private static let appName = "zia-chat-ios"
    private static let heartbeatInterval: TimeInterval = 15
    private static let maxSamples = 40
    private static let maxBreadcrumbs = 40
    private static let maxPendingReports = 25
    private static let maxPayloadCharacters = 500_000
    private static let pendingMaxAge: TimeInterval = 21 * 24 * 60 * 60
    private static let sentIdsDefaultsKey = "zia.diagnostics.sentIds"

    /// Todo el estado mutable y el disco se tocan solo desde esta cola.
    private let queue = DispatchQueue(label: "zia.diagnostics", qos: .utility)
    private var session: SessionRecord?
    private var timer: DispatchSourceTimer?
    private var lastCPUTime: Double = 0
    private var lastSampleAt = Date()
    private var observers: [NSObjectProtocol] = []
    private let isSending = OSAllocatedUnfairLock(initialState: false)

    private override init() {
        super.init()
        queue.setSpecific(key: Self.queueKey, value: true)
    }

    // MARK: - Arranque

    /// Llamar una vez, al lanzar la app.
    func start() {
        guard !ZiaDemoMode.isEnabled else { return }
        let center = NotificationCenter.default
        let states: [(Notification.Name, String)] = [
            (UIApplication.didBecomeActiveNotification, "active"),
            (UIApplication.willResignActiveNotification, "inactive"),
            (UIApplication.didEnterBackgroundNotification, "background"),
            (UIApplication.willEnterForegroundNotification, "inactive"),
        ]
        for (name, state) in states {
            observers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in
                self?.queue.async { self?.setState(state) }
            })
        }
        observers.append(center.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.recordMemoryWarning() }
        })
        observers.append(center.addObserver(
            forName: UIApplication.willTerminateNotification, object: nil, queue: nil
        ) { [weak self] _ in
            // Síncrono: el proceso muere al volver de esta notificación.
            self?.queue.sync { self?.markCleanExit() }
        })

        queue.async { [self] in
            reportPreviousSessionIfNeeded()
            beginSession()
            prunePendingReports()
        }

        MXMetricManager.shared.add(self)
        let past = MXMetricManager.shared.pastDiagnosticPayloads
        if !past.isEmpty {
            handle(diagnosticPayloads: past)
        }
    }

    /// Marca un evento en la bitácora de la sesión ("renovó sesión", "reconexión"…).
    func breadcrumb(_ text: String) {
        let now = Date()
        queue.async { [self] in
            guard var current = session else { return }
            current.breadcrumbs.append(Breadcrumb(t: Int(now.timeIntervalSince(current.startedAt)), text: String(text.prefix(200))))
            if current.breadcrumbs.count > Self.maxBreadcrumbs {
                current.breadcrumbs.removeFirst(current.breadcrumbs.count - Self.maxBreadcrumbs)
            }
            session = current
            writeSession()
        }
    }

    /// Manda lo pendiente. Llamar cuando haya sesión vigente (arranque, al
    /// renovar el token, al volver a primer plano).
    @MainActor
    func flush(configuration: CoreAppConfiguration) {
        guard configuration.isUsable, !ZiaDemoMode.isEnabled,
              let client = try? ConvexCoreClient(configuration: configuration) else { return }
        Task.detached(priority: .utility) { [self] in
            await sendPending(using: client)
        }
    }

    // MARK: - MetricKit

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        handle(diagnosticPayloads: payloads)
        flushWithCurrentSession()
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for payload in payloads {
            guard let exits = payload.applicationExitMetrics else { continue }
            let foreground = exits.foregroundExitData
            let background = exits.backgroundExitData
            let counts: [(String, Int)] = [
                ("primer plano · límite de memoria", foreground.cumulativeMemoryResourceLimitExitCount),
                ("primer plano · acceso inválido", foreground.cumulativeBadAccessExitCount),
                ("primer plano · instrucción ilegal", foreground.cumulativeIllegalInstructionExitCount),
                ("primer plano · anormal", foreground.cumulativeAbnormalExitCount),
                ("primer plano · watchdog", foreground.cumulativeAppWatchdogExitCount),
                ("segundo plano · límite de memoria", background.cumulativeMemoryResourceLimitExitCount),
                ("segundo plano · presión de memoria", background.cumulativeMemoryPressureExitCount),
                ("segundo plano · límite de CPU", background.cumulativeCPUResourceLimitExitCount),
                ("segundo plano · acceso inválido", background.cumulativeBadAccessExitCount),
                ("segundo plano · instrucción ilegal", background.cumulativeIllegalInstructionExitCount),
                ("segundo plano · anormal", background.cumulativeAbnormalExitCount),
                ("segundo plano · watchdog", background.cumulativeAppWatchdogExitCount),
                ("segundo plano · tarea sin terminar", background.cumulativeBackgroundTaskAssertionTimeoutExitCount),
                ("segundo plano · archivo bloqueado", background.cumulativeSuspendedWithLockedFileExitCount),
            ].filter { $0.1 > 0 }
            guard !counts.isEmpty else { continue }
            let summary = "Salidas del día: " + counts.map { "\($0.0) ×\($0.1)" }.joined(separator: ", ")
                + " (normales en primer plano ×\(foreground.cumulativeNormalAppExitCount))"
            let json = String(data: exits.jsonRepresentation(), encoding: .utf8) ?? "{}"
            enqueue(
                kind: "exit_summary",
                summary: summary,
                payload: json,
                occurredAt: payload.timeStampEnd,
                appVersion: payload.metaData?.applicationBuildVersion,
                osVersion: payload.metaData?.osVersion,
                deviceModel: payload.metaData?.deviceType,
                reportId: Self.stableId("exit_summary", "\(payload.timeStampBegin.timeIntervalSince1970)-\(payload.timeStampEnd.timeIntervalSince1970)")
            )
        }
        flushWithCurrentSession()
    }

    private func handle(diagnosticPayloads payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            let meta = { (data: MXMetaData) in
                (data.applicationBuildVersion, data.osVersion, data.deviceType)
            }
            for crash in payload.crashDiagnostics ?? [] {
                var parts: [String] = []
                if let signal = crash.signal?.intValue { parts.append("señal \(Self.signalName(signal))") }
                if let type = crash.exceptionType?.intValue { parts.append("excepción \(Self.exceptionName(type))") }
                if let code = crash.exceptionCode { parts.append("código \(code)") }
                if let reason = crash.terminationReason, !reason.isEmpty { parts.append(reason) }
                if let message = crash.exceptionReason?.composedMessage, !message.isEmpty { parts.append(message) }
                if let region = crash.virtualMemoryRegionInfo, !region.isEmpty { parts.append(String(region.prefix(300))) }
                let (build, os, device) = meta(crash.metaData)
                enqueueDiagnostic(kind: "crash", summary: "Crash: " + parts.joined(separator: " · "),
                                  json: crash.jsonRepresentation(), occurredAt: payload.timeStampEnd,
                                  build: build, os: os, device: device)
            }
            for hang in payload.hangDiagnostics ?? [] {
                let seconds = hang.hangDuration.converted(to: .seconds).value
                let (build, os, device) = meta(hang.metaData)
                enqueueDiagnostic(kind: "hang", summary: String(format: "Bloqueo del hilo principal de %.1f s", seconds),
                                  json: hang.jsonRepresentation(), occurredAt: payload.timeStampEnd,
                                  build: build, os: os, device: device)
            }
            for cpu in payload.cpuExceptionDiagnostics ?? [] {
                let used = cpu.totalCPUTime.converted(to: .seconds).value
                let sampled = cpu.totalSampledTime.converted(to: .seconds).value
                let (build, os, device) = meta(cpu.metaData)
                enqueueDiagnostic(kind: "cpu", summary: String(format: "Exceso de CPU: %.0f s de CPU en %.0f s", used, sampled),
                                  json: cpu.jsonRepresentation(), occurredAt: payload.timeStampEnd,
                                  build: build, os: os, device: device)
            }
        }
    }

    private func enqueueDiagnostic(
        kind: String, summary: String, json: Data, occurredAt: Date,
        build: String, os: String, device: String
    ) {
        let text = String(data: json, encoding: .utf8) ?? "{}"
        enqueue(kind: kind, summary: summary, payload: text, occurredAt: occurredAt,
                appVersion: build, osVersion: os, deviceModel: device,
                reportId: Self.stableId(kind, text))
    }

    private func flushWithCurrentSession() {
        Task { @MainActor in
            self.flush(configuration: ContentView.sharedStore.configuration)
        }
    }

    // MARK: - Bitácora de sesión

    private func beginSession() {
        let now = Date()
        lastSampleAt = now
        lastCPUTime = Self.processCPUTime()
        session = SessionRecord(
            id: UUID().uuidString,
            startedAt: now,
            updatedAt: now,
            appVersion: Self.appVersion,
            osVersion: Self.osVersion,
            deviceModel: Self.deviceModel,
            state: "inactive",
            cleanExit: false,
            debugger: Self.isDebuggerAttached(),
            memoryWarnings: 0,
            samples: [],
            breadcrumbs: []
        )
        takeSample()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.heartbeatInterval, repeating: Self.heartbeatInterval, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.takeSample() }
        timer.resume()
        self.timer = timer
    }

    private func setState(_ state: String) {
        guard session != nil, session?.state != state else { return }
        session?.state = state
        takeSample()
    }

    private func recordMemoryWarning() {
        guard session != nil else { return }
        session?.memoryWarnings += 1
        takeSample()
    }

    private func markCleanExit() {
        guard session != nil else { return }
        session?.cleanExit = true
        session?.updatedAt = Date()
        writeSession()
    }

    private func takeSample() {
        guard var current = session else { return }
        let now = Date()
        let cpuTime = Self.processCPUTime()
        let elapsed = now.timeIntervalSince(lastSampleAt)
        let cpuPercent = elapsed > 0.5 ? Int(((cpuTime - lastCPUTime) / elapsed * 100).rounded()) : 0
        lastCPUTime = cpuTime
        lastSampleAt = now

        current.samples.append(Sample(
            t: Int(now.timeIntervalSince(current.startedAt)),
            memMB: Int(Self.memoryFootprint() / 1_048_576),
            freeMB: Int(os_proc_available_memory() / 1_048_576),
            cpu: max(0, cpuPercent),
            threads: Self.threadCount(),
            thermal: ProcessInfo.processInfo.thermalState.rawValue,
            state: current.state
        ))
        if current.samples.count > Self.maxSamples {
            // Conserva la primera (memoria al arrancar) y las más recientes.
            current.samples.removeSubrange(1...(current.samples.count - Self.maxSamples))
        }
        current.updatedAt = now
        if Self.isDebuggerAttached() { current.debugger = true }
        session = current
        writeSession()
    }

    /// Si la sesión anterior murió en primer plano sin `willTerminate`, la
    /// manda como reporte. En segundo plano el sistema cierra apps a diario
    /// sin que sea un fallo, así que eso no se reporta.
    private func reportPreviousSessionIfNeeded() {
        guard let url = sessionURL, let data = try? Data(contentsOf: url),
              let previous = try? Self.decoder.decode(SessionRecord.self, from: data) else { return }
        try? FileManager.default.removeItem(at: url)
        // Detener la app desde Xcode también la mata sin aviso.
        guard !previous.cleanExit, previous.state == "active", !previous.debugger,
              let last = previous.samples.last else { return }

        let first = previous.samples.first ?? last
        let peak = previous.samples.map(\.memMB).max() ?? last.memMB
        let duration = Int(previous.updatedAt.timeIntervalSince(previous.startedAt))
        var summary = "Se cerró en primer plano a los \(Self.durationText(duration)). "
            + "Memoria \(last.memMB) MB (al abrir \(first.memMB) MB, máximo \(peak) MB, libre \(last.freeMB) MB), "
            + "CPU \(last.cpu) %, \(last.threads) hilos"
        if previous.memoryWarnings > 0 { summary += ", \(previous.memoryWarnings) avisos de memoria" }
        if last.thermal >= 2 { summary += ", teléfono caliente" }
        if let crumb = previous.breadcrumbs.last { summary += ". Último evento: \(crumb.text)" }

        enqueue(
            kind: "unclean_exit",
            summary: summary,
            payload: String(data: data, encoding: .utf8) ?? "{}",
            occurredAt: previous.updatedAt,
            appVersion: previous.appVersion,
            osVersion: previous.osVersion,
            deviceModel: previous.deviceModel,
            reportId: "exit-\(previous.id)"
        )
    }

    // MARK: - Pendientes en disco

    private func enqueue(
        kind: String, summary: String, payload: String, occurredAt: Date,
        appVersion: String?, osVersion: String?, deviceModel: String?, reportId: String
    ) {
        let report = PendingReport(
            reportId: reportId,
            kind: kind,
            summary: String(summary.prefix(1_900)),
            payload: payload.count > Self.maxPayloadCharacters
                ? String(payload.prefix(Self.maxPayloadCharacters)) + "…[recortado]"
                : payload,
            appVersion: appVersion ?? Self.appVersion,
            osVersion: osVersion ?? Self.osVersion,
            deviceModel: deviceModel ?? Self.deviceModel,
            occurredAt: occurredAt
        )
        let write: @Sendable () -> Void = { [self] in
            guard !sentIds().contains(reportId), let url = pendingURL(reportId),
                  !FileManager.default.fileExists(atPath: url.path),
                  let data = try? Self.encoder.encode(report) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
            Self.logger.info("Reporte en cola: \(kind, privacy: .public) — \(report.summary, privacy: .public)")
        }
        // `reportPreviousSessionIfNeeded` ya corre dentro de la cola.
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { write() } else { queue.async(execute: write) }
    }

    private func sendPending(using client: ConvexCoreClient) async {
        guard isSending.withLock({ sending in
            if sending { return false }
            sending = true
            return true
        }) else { return }
        defer { isSending.withLock { $0 = false } }

        for url in pendingFiles() {
            guard let data = try? Data(contentsOf: url),
                  let report = try? Self.decoder.decode(PendingReport.self, from: data) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            do {
                try await client.reportDiagnostic(
                    reportId: report.reportId,
                    app: Self.appName,
                    kind: report.kind,
                    summary: report.summary,
                    payload: report.payload,
                    appVersion: report.appVersion,
                    osVersion: report.osVersion,
                    deviceModel: report.deviceModel,
                    occurredAt: report.occurredAt
                )
                try? FileManager.default.removeItem(at: url)
                rememberSent(report.reportId)
                Self.logger.info("Reporte enviado: \(report.kind, privacy: .public)")
            } catch {
                // Sin red, sesión vencida o backend sin desplegar: queda en
                // disco y se reintenta en el siguiente `flush`.
                Self.logger.error("No se pudo enviar el reporte: \(error.localizedDescription, privacy: .public)")
                return
            }
        }
    }

    private func pendingFiles() -> [URL] {
        guard let directory = pendingDirectory,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
              ) else { return [] }
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { Self.modificationDate($0) < Self.modificationDate($1) }
    }

    private func prunePendingReports() {
        let files = pendingFiles()
        let expired = files.filter { Date().timeIntervalSince(Self.modificationDate($0)) > Self.pendingMaxAge }
        let overflow = files.dropLast(Self.maxPendingReports)
        for url in Set(expired).union(overflow) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func sentIds() -> [String] {
        UserDefaults.standard.stringArray(forKey: Self.sentIdsDefaultsKey) ?? []
    }

    private func rememberSent(_ reportId: String) {
        var ids = sentIds()
        ids.append(reportId)
        UserDefaults.standard.set(Array(ids.suffix(300)), forKey: Self.sentIdsDefaultsKey)
    }

    private func writeSession() {
        guard let url = sessionURL, let session, let data = try? Self.encoder.encode(session) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    private static let queueKey = DispatchSpecificKey<Bool>()

    private var rootDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("zia-diagnostics", isDirectory: true)
    }

    private var sessionURL: URL? { rootDirectory?.appendingPathComponent("session.json") }
    private var pendingDirectory: URL? { rootDirectory?.appendingPathComponent("pending", isDirectory: true) }

    private func pendingURL(_ reportId: String) -> URL? {
        guard let name = reportId.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else { return nil }
        return pendingDirectory?.appendingPathComponent("\(name).json")
    }

    // MARK: - Modelos

    private struct Sample: Codable, Sendable {
        /// Segundos desde que abrió la app.
        var t: Int
        var memMB: Int
        var freeMB: Int
        var cpu: Int
        var threads: Int
        /// 0 normal · 1 templado · 2 caliente · 3 crítico.
        var thermal: Int
        var state: String
    }

    private struct Breadcrumb: Codable, Sendable {
        var t: Int
        var text: String
    }

    private struct SessionRecord: Codable, Sendable {
        var id: String
        var startedAt: Date
        var updatedAt: Date
        var appVersion: String
        var osVersion: String
        var deviceModel: String
        var state: String
        var cleanExit: Bool
        var debugger: Bool
        var memoryWarnings: Int
        var samples: [Sample]
        var breadcrumbs: [Breadcrumb]
    }

    private struct PendingReport: Codable, Sendable {
        var reportId: String
        var kind: String
        var summary: String
        var payload: String
        var appVersion: String
        var osVersion: String
        var deviceModel: String
        var occurredAt: Date
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: - Datos del proceso y del dispositivo

    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private static var osVersion: String {
        "iOS " + ProcessInfo.processInfo.operatingSystemVersionString
    }

    private static var deviceModel: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return "Simulador \(simulated)"
        }
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
    }

    /// Memoria que el sistema le cuenta a la app (la que dispara el cierre por límite).
    private static func memoryFootprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : 0
    }

    /// Segundos de CPU (usuario + sistema) consumidos por el proceso.
    private static func processCPUTime() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    private static func threadCount() -> Int {
        var threads: thread_act_array_t?
        var count: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &count) == KERN_SUCCESS, let threads else { return 0 }
        vm_deallocate(
            mach_task_self_,
            vm_address_t(UInt(bitPattern: threads)),
            vm_size_t(Int(count) * MemoryLayout<thread_t>.stride)
        )
        return Int(count)
    }

    private static func isDebuggerAttached() -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, UInt32(name.count), &info, &size, nil, 0) == 0 else { return false }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }

    private static func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    private static func stableId(_ kind: String, _ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return kind + "-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    private static func durationText(_ seconds: Int) -> String {
        seconds < 60 ? "\(seconds) s" : "\(seconds / 60) min \(seconds % 60) s"
    }

    private static func signalName(_ signal: Int) -> String {
        switch signal {
        case 4: "SIGILL"
        case 5: "SIGTRAP"
        case 6: "SIGABRT"
        case 9: "SIGKILL"
        case 10: "SIGBUS"
        case 11: "SIGSEGV"
        default: "\(signal)"
        }
    }

    private static func exceptionName(_ type: Int) -> String {
        switch type {
        case 1: "EXC_BAD_ACCESS"
        case 2: "EXC_BAD_INSTRUCTION"
        case 3: "EXC_ARITHMETIC"
        case 5: "EXC_SOFTWARE"
        case 6: "EXC_BREAKPOINT"
        case 10: "EXC_CRASH"
        case 11: "EXC_RESOURCE"
        case 12: "EXC_GUARD"
        default: "\(type)"
        }
    }
}
