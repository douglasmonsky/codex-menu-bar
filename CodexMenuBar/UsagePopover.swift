import SwiftUI

struct UsagePopover: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Codex Usage")
                .font(.headline)
            if let snapshot = model.snapshot {
                ForEach(snapshot.windows) { window in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(window.displayLabel)
                            Spacer()
                            Text("\(Int(window.remainingPercent.rounded()))%")
                                .fontWeight(.semibold)
                        }
                        if let reset = window.resetsAt {
                            Text(resetText(reset))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Divider()
                Text("Last updated \(snapshot.fetchedAt.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Divider()
                Text(
                    "\(model.taskActivity.running.count) running · "
                    + "\(model.taskActivity.finished.count) finished in the last 2h"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            } else if model.connectionState == .notAuthenticated {
                Text("Codex is not signed in for ChatGPT usage.\nSign in with the Codex CLI, then choose Retry.")
                    .font(.callout)
            } else {
                Text(model.statusText)
                    .foregroundStyle(.secondary)
            }
            Text(model.widgetSyncText)
                .font(.caption)
                .foregroundStyle(.secondary)
            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                if model.shouldShowLocate {
                    Button("Locate Codex…") { locateCodex() }
                }
                if model.shouldShowRetry {
                    Button("Retry") { model.restart() }
                }
                Button("Refresh Now") { model.refreshNow() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func locateCodex() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            model.selectExecutable(url)
        }
    }

    private func resetText(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(.dateTime.hour().minute())
        if calendar.isDateInToday(date) { return "Resets today at \(time)" }
        if calendar.dateInterval(of: .weekOfYear, for: Date())?.contains(date) == true {
            return "Resets \(date.formatted(.dateTime.weekday(.wide))) at \(time)"
        }
        return "Resets \(date.formatted(.dateTime.month(.wide).day())) at \(time)"
    }
}
