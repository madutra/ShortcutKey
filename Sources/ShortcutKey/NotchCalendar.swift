import AppKit
import EventKit
import SwiftUI

/// Eventos do app Calendário para a aba "Início" do notch.
final class NotchCalendar: ObservableObject {
    static let shared = NotchCalendar()

    enum Access { case notDetermined, denied, granted }

    struct Event: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let isAllDay: Bool
        let location: String?
        let color: NSColor
    }

    @Published private(set) var access: Access = .notDetermined
    @Published private(set) var selectedDay = Calendar.current.startOfDay(for: Date())
    @Published private(set) var events: [Event] = []
    /// Dias que aparecem na faixa (de uma semana atrás até duas semanas à frente).
    @Published private(set) var days: [Date] = []
    /// Dias da faixa que têm algum evento (para a bolinha embaixo do número).
    @Published private(set) var daysWithEvents: Set<Date> = []
    /// +1 quando o dia escolhido é depois do anterior, -1 quando é antes (direção da animação).
    @Published private(set) var direction = 1

    private let store = EKEventStore()
    private var started = false

    func start() {
        if !started {
            started = true
            NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
                self?.reload()
            }
        }
        updateAccess()
        // Ao virar o dia, a faixa volta para "hoje".
        let today = Calendar.current.startOfDay(for: Date())
        if days.first.map({ Calendar.current.date(byAdding: .day, value: 7, to: $0) != today }) ?? true {
            days = (-7...14).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: today) }
            selectedDay = today
        }
        reload()
    }

    func requestAccess() {
        if access == .denied {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async { self?.updateAccess(); self?.reload() }
        }
    }

    func select(_ day: Date) {
        let day = Calendar.current.startOfDay(for: day)
        guard day != selectedDay else { return }
        direction = day > selectedDay ? 1 : -1
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            selectedDay = day
            reload()
        }
    }

    func openCalendarApp() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func reloadMarkers() {
        guard access == .granted, let first = days.first, let last = days.last,
              let end = Calendar.current.date(byAdding: .day, value: 1, to: last) else { return }
        let predicate = store.predicateForEvents(withStart: first, end: end, calendars: nil)
        daysWithEvents = Set(store.events(matching: predicate).map { Calendar.current.startOfDay(for: $0.startDate) })
    }

    private func updateAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: access = .granted
        case .notDetermined: access = .notDetermined
        default: access = .denied
        }
    }

    private func reload() {
        reloadMarkers()
        guard access == .granted,
              let end = Calendar.current.date(byAdding: .day, value: 1, to: selectedDay) else {
            events = []
            return
        }
        let predicate = store.predicateForEvents(withStart: selectedDay, end: end, calendars: nil)
        events = store.events(matching: predicate)
            .sorted { ($0.isAllDay ? 0 : 1, $0.startDate) < ($1.isAllDay ? 0 : 1, $1.startDate) }
            .map { event in
                Event(id: event.eventIdentifier ?? UUID().uuidString,
                      title: event.title ?? "Sem título",
                      start: event.startDate,
                      end: event.endDate,
                      isAllDay: event.isAllDay,
                      location: event.location.flatMap { $0.isEmpty ? nil : $0 },
                      color: event.calendar.map { NSColor(cgColor: $0.cgColor) ?? .systemBlue } ?? .systemBlue)
            }
    }
}
