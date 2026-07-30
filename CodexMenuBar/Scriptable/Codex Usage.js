// Managed by Codex Menu Bar
const widget = new ListWidget()
widget.backgroundColor = new Color("#171C20")
widget.setPadding(14, 14, 14, 14)

const title = widget.addText("Codex Usage")
title.font = Font.semiboldSystemFont(13)
title.textColor = Color.white()

widget.addSpacer(8)

const fileManager = FileManager.iCloud()
const dataPath = fileManager.joinPath(
  fileManager.documentsDirectory(),
  "codex-usage.json"
)

if (!fileManager.fileExists(dataPath)) {
  const message = widget.addText("Waiting for the Mac app to sync.")
  message.font = Font.systemFont(12)
  message.textColor = Color.gray()
} else {
  try {
    await fileManager.downloadFileFromiCloud(dataPath)
    const payload = JSON.parse(fileManager.readString(dataPath))
    if (!Array.isArray(payload.windows) || !payload.updatedAt) {
      throw new Error("Invalid usage data")
    }
    const now = new Date()

    const values = payload.windows.map(window => {
      const percent = `${Math.round(window.remainingPercent)}%`
      if (window.compactLabel !== "W") {
        return `${window.compactLabel} ${percent}`
      }
      if (!window.resetsAt) {
        return percent
      }

      const reset = new Date(window.resetsAt)
      const remainingHours = Math.max(
        0,
        Math.ceil((reset.getTime() - now.getTime()) / 3_600_000)
      )
      const days = Math.floor(remainingHours / 24)
      const hours = remainingHours % 24
      return `${percent} · ${days}d ${hours}h`
    })

    const usage = widget.addText(values.join(" · "))
    usage.font = Font.semiboldMonospacedSystemFont(14)
    usage.textColor = Color.white()
    usage.minimumScaleFactor = 0.7

    widget.addSpacer(7)

    const tasks = payload.tasks || { running: [], finished: [] }
    const running = Array.isArray(tasks.running) ? tasks.running : []
    const finished = Array.isArray(tasks.finished) ? tasks.finished : []
    const runningCount = Number.isInteger(tasks.runningCount) ? tasks.runningCount : running.length
    const finishedCount = Number.isInteger(tasks.finishedCount) ? tasks.finishedCount : finished.length
    const summary = widget.addText(`● ${runningCount} running   ✓ ${finishedCount} finished`)
    summary.font = Font.semiboldSystemFont(11)
    summary.textColor = new Color("#AAB4BC")

    const rows = [
      ...running.map(task => ({ prefix: "●", color: "#67D391", ...task })),
      ...finished.map(task => ({ prefix: "✓", color: "#8E9AA3", ...task }))
    ]
    const maximumRows = config.widgetFamily === "small" ? 1 : 4
    for (const task of rows.slice(0, maximumRows)) {
      const row = widget.addText(`${task.prefix} ${task.title}`)
      row.font = Font.systemFont(10)
      row.textColor = new Color(task.color)
      row.lineLimit = 1
      row.minimumScaleFactor = 0.75
    }

    widget.addSpacer()

    const updated = new Date(payload.updatedAt)
    const freshness = widget.addText(`Updated ${updated.toLocaleTimeString([], {
      hour: "numeric",
      minute: "2-digit"
    })}`)
    freshness.font = Font.systemFont(10)
    freshness.textColor = Color.gray()
  } catch (error) {
    const message = widget.addText("Sync unavailable. Open Scriptable to retry.")
    message.font = Font.systemFont(12)
    message.textColor = Color.gray()
  }
}

widget.refreshAfterDate = new Date(Date.now() + 15 * 60 * 1000)
Script.setWidget(widget)
Script.complete()
