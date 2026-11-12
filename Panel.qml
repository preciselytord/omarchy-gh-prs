import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// GitHub PRs: your open pull requests and whether their checks pass.
//
// The bar shows a count of PRs with failing checks (or failing and running,
// by setting); the panel lists every open PR, grouped by repository,
// newest activity first, with a dot for its checks, a
// word saying where they are, and how long since it last moved.
//
// Hovering a row shows a summary. Clicking it opens the detail view: every
// check by name, who reviewed and who is still asked, whether GitHub would
// take a merge, and the buttons that act on the PR. The detail view is part
// of the panel rather than a tooltip, because a tooltip cannot hold buttons:
// it closes as the pointer leaves the row on its way to them.
//
// `bin/gh-prs` does the GitHub side through the user's own `gh` login, so
// nothing here holds a token.
//
// Titles, owners, branches and check names are whatever someone typed on
// GitHub, so every Text carries `textFormat: Text.PlainText`. Left on the
// default AutoText, Qt decides for itself that a string looks like markup and
// renders it as rich text, and rich text loads `<img src="http://...">`.
//
// Glyphs are \u escapes rather than literal characters, so the source
// survives editors and patches that mangle private-use codepoints.
Panel {
  id: root

  moduleName: "io.github.travisjeffery.gh-prs"
  ipcTarget: "io.github.travisjeffery.gh-prs"

  readonly property string script:
    Qt.resolvedUrl("bin/gh-prs").toString().replace(/^file:\/\//, "")

  // nf-oct-git_pull_request
  readonly property string iconPr: ""
  readonly property string iconDot: ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  // Omarchy themes carry no green or yellow, and "passing" and "running" are
  // green and yellow on every CI page there is. Borrowing the accent for
  // either would make the two read alike, which is the one distinction this
  // panel exists to draw, so these are picked rather than themed.
  readonly property color passing: "#5FA46B"
  readonly property color running: "#D7A63A"
  readonly property color quiet: Qt.darker(foreground, 1.9)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // A PR nobody has touched in two weeks is either waiting on someone or
  // forgotten; either way it should look different from this morning's.
  readonly property int staleDays: 14

  // ------------------------------------------------------------- settings

  // What the badge counts: "failing", "active" (failing and running) or
  // "none". Drafts stay out of it unless asked for: a draft is work you have
  // already said is not ready, and its red check is not news.
  readonly property string badgeMode: {
    var m = String(setting("badge", "failing"))
    return m === "active" || m === "none" ? m : "failing"
  }
  readonly property bool badgeDrafts: setting("badgeDrafts", false) === true
  readonly property int intervalSeconds:
    Math.max(30, Number(setting("interval", 60)) || 60)
  readonly property string query: String(setting("query", ""))
  // "status" puts what is ready to merge on top; "date" is plain recency.
  // Chosen from the header and kept in the plugin's own state file rather
  // than in shell.json: other widgets save shell.json from their own copy of
  // it, and a choice written there was seen to be overwritten seconds later.
  property string sortMode: "status"
  // Repositories folded down to their heading, as { "owner/name": true }.
  // Kept in the plugin's state file, like the sort order, so a fold stays
  // folded after the panel closes and the shell restarts.
  property var collapsed: ({})

  // ---------------------------------------------------------------- state

  property var payload: null
  property var rows: []
  property bool reachable: true
  property string errorText: ""
  property bool loading: false
  property int cursor: -1
  // Ages are drawn against this rather than Date.now(), so they move when the
  // list refreshes instead of never.
  property real now: Date.now()

  // The detail view. `selected` is the row that was clicked, which is enough
  // to draw the header at once; `detail` is the fuller record fetched for it.
  property string view: "list"
  property var selected: null
  property var detail: null
  property bool detailLoading: false
  property string detailError: ""
  // "merge" or "close" while that action is waiting on its confirm click.
  property string confirm: ""
  property bool deleteBranch: false
  property string actionBusy: ""
  property var actionResult: null
  property bool copied: false
  // The Claude sessions linked from the PR shown: each a claude.ai link, with
  // its Herdr pane when it runs here.
  property var sessions: []
  // Auto-merge as last set from this view, until the list catches up: the
  // row the view was opened from still says what it said then.
  property var autoMergeSet: null

  readonly property int badgeCount: {
    if (!payload || badgeMode === "none") return 0
    var b = payload.badge || {}
    var n = b.failing || 0
    if (badgeDrafts) n += b.failingDrafts || 0
    if (badgeMode === "active") {
      n += b.running || 0
      if (badgeDrafts) n += b.runningDrafts || 0
    }
    return n
  }
  readonly property bool badgeAlarm: {
    if (!payload) return false
    var b = payload.badge || {}
    return (b.failing || 0) + (badgeDrafts ? (b.failingDrafts || 0) : 0) > 0
  }

  // The bar hands a Panel zero width unless it is computed here, from
  // content, never from a child. The icon takes a standard bar slot and the
  // badge sits beside it, not inside an iconComponent: the bar scales a
  // custom icon until its widest side fits the icon size, which shrank the
  // whole icon-plus-badge row to a speck.
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int badgeHeight: Style.space(10)
  readonly property int badgeFont: Style.space(8)
  readonly property int badgeWidth: badgeCount > 0
    ? Math.max(badgeHeight, String(badgeCount).length * Style.space(5) + Style.space(5))
    : 0
  // The badge starts just past the icon's painted edge, so the widget keeps
  // the slot's own padding after it.
  readonly property int badgeGap: Style.space(2)
  readonly property real badgeStart: (Style.bar.iconSlot + Style.bar.iconSize) / 2 + badgeGap
  readonly property int badgeExtent: badgeCount > 0
    ? badgeGap + (vertical ? badgeHeight : badgeWidth)
    : 0
  readonly property int barSlot: Style.bar.iconSlot + badgeExtent

  implicitWidth: vertical ? (bar ? bar.barSize : Style.bar.sizeVertical) : barSlot
  implicitHeight: vertical ? barSlot : (bar ? bar.barSize : Style.bar.sizeHorizontal)

  // --------------------------------------------------------------- helpers

  // Only a PR page on some GitHub host is ever handed to xdg-open. The URL
  // came from GitHub, but it still leaves this process as an argument. The
  // script checks every argument again; this is the near end of the fence.
  function validUrl(url) {
    return /^https:\/\/[A-Za-z0-9.-]+\/[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\/pull\/[0-9]+$/.test(String(url))
  }
  function validRepo(repo) {
    return /^[A-Za-z0-9_.-]{1,100}\/[A-Za-z0-9_.-]{1,100}$/.test(String(repo))
  }

  function plain(s) {
    return String(s || "").replace(/[<>]/g, "")
  }

  // Auto-merge moves on every refresh: the script takes each armed PR one
  // step (rebase, wait or merge) and the list is read after it, so it shows
  // where they got to.
  function tick() {
    if (tickProc.running) { refresh(); return }
    tickProc.command = [root.script, "automerge", "tick"]
    tickProc.running = true
  }

  function refresh() {
    if (listProc.running) return
    loading = true
    listProc.command = [root.script, "list", root.query]
    listProc.running = true
  }

  function openPr(pr) {
    if (!pr || !validUrl(pr.url)) return
    Util.execArgv(["xdg-open", pr.url])
    close()
  }

  // ---------------------------------------------------------------- dates

  function ageSeconds(iso) {
    var t = Date.parse(iso)
    return isNaN(t) ? 0 : Math.max(0, (root.now - t) / 1000)
  }

  function ago(seconds) {
    var m = seconds / 60, h = m / 60, d = h / 24
    if (m < 1) return "now"
    if (h < 1) return Math.floor(m) + "m"
    if (d < 1) return Math.floor(h) + "h"
    if (d < 14) return Math.floor(d) + "d"
    if (d < 60) return Math.floor(d / 7) + "w"
    if (d < 365) return Math.floor(d / 30) + "mo"
    return Math.floor(d / 365) + "y"
  }

  function stale(pr) {
    return pr && ageSeconds(pr.updatedAt) > root.staleDays * 86400
  }

  function when(iso) {
    if (!iso) return ""
    var d = new Date(iso)
    return Qt.formatDateTime(d, "d MMM yyyy HH:mm") + "  (" + ago(ageSeconds(iso)) + " ago)"
  }

  // ------------------------------------------------------------- the list

  // Repository headings and PR rows in one flat list, so one ListView scrolls the
  // lot and the cursor can step over the headings.
  // Repositories always come in the same order, alphabetical, so each one
  // stays where you last saw it. The sort applies within each: by status,
  // passing first, then running, failing, and no checks, drafts after the
  // rest within each, newest first within that; by date, newest first. The
  // script sends PRs by date and repositories alphabetically (group_by).
  function sortGroups(groups) {
    if (sortMode === "date") return groups
    var rank = { passing: 0, running: 1, failing: 2, none: 3 }
    function newest(a, b) { return a.updatedAt < b.updatedAt ? 1 : a.updatedAt > b.updatedAt ? -1 : 0 }
    var out = groups.map(function(g) {
      var prs = g.prs.slice().sort(function(a, b) {
        return (rank[a.state] - rank[b.state])
          || ((a.draft ? 1 : 0) - (b.draft ? 1 : 0))
          || newest(a, b)
      })
      return { repo: g.repo, failing: g.failing, prs: prs }
    })
    return out
  }

  function setSort(mode) {
    if ((mode !== "status" && mode !== "date") || mode === sortMode) return
    sortMode = mode
    Util.execArgv([root.script, "sort", mode])
  }

  function rebuildRows() {
    rows = flatten(sortGroups(payload ? payload.groups || [] : []))
    if (cursor >= rows.length) cursor = -1
  }

  function toggleCollapsed(repo) {
    if (!validRepo(repo)) return
    var next = Object.assign({}, collapsed)
    var on = !next[repo]
    if (on) next[repo] = true
    else delete next[repo]
    collapsed = next
    rebuildRows()
    // The heading moves (folded ones go last), so the cursor follows it.
    for (var i = 0; i < rows.length; i++)
      if (rows[i].kind === "repo" && rows[i].repo === repo) { cursor = i; list.positionViewAtIndex(i, ListView.Contain); break }
    Util.execArgv([root.script, "collapsed", repo, on ? "on" : "off"])
  }

  function applyCollapsed(text) {
    try {
      var list = JSON.parse(text)
      var next = {}
      for (var i = 0; i < list.length; i++) if (validRepo(list[i])) next[list[i]] = true
      collapsed = next
      rebuildRows()
    } catch (e) {}
  }

  onSortModeChanged: rebuildRows()

  // Folded repositories go to the bottom, alphabetical among themselves, so
  // the open ones stay together at the top.
  function flatten(groups) {
    var out = []
    var ordered = groups.filter(function(g) { return !collapsed[g.repo] })
      .concat(groups.filter(function(g) { return !!collapsed[g.repo] }))
    for (var i = 0; i < ordered.length; i++) {
      var g = ordered[i]
      var folded = !!collapsed[g.repo]
      out.push({ kind: "repo", repo: g.repo, count: g.prs.length, failing: g.failing, collapsed: folded })
      if (folded) continue
      for (var j = 0; j < g.prs.length; j++) {
        var pr = g.prs[j]
        pr.kind = "pr"
        out.push(pr)
      }
    }
    return out
  }

  function isPr(i) {
    return i >= 0 && i < rows.length && rows[i].kind === "pr"
  }

  function moveCursor(delta) {
    var next = cursor
    for (var step = 0; step < rows.length; step++) {
      next += delta
      if (next < 0 || next >= rows.length) return
      break
    }
    if (next < 0 || next >= rows.length) return
    cursor = next
    list.positionViewAtIndex(next, ListView.Contain)
  }

  function stateColor(state) {
    if (state === "failing") return root.urgent
    if (state === "running") return root.running
    if (state === "passing") return root.passing
    return root.quiet
  }

  function reviewColor(review) {
    if (review === "approved") return root.passing
    if (review === "changes requested") return root.urgent
    return root.quiet
  }

  function subtitleFor(pr) {
    if (!pr) return ""
    var s = "#" + pr.number
    if (pr.draft) s += "  ·  draft"
    if (pr.autoMerge) s += "  ·  auto-merge: " + pr.autoMerge.status
    return s
  }

  function ageLabel(pr) {
    if (!pr) return ""
    var a = ago(ageSeconds(pr.updatedAt))
    return stale(pr) ? "stale · " + a : a
  }

  // What a hover shows: enough to recognise the PR and see where it stands,
  // without opening it.
  function summaryText(pr) {
    if (!pr || pr.kind !== "pr") return ""
    var lines = [pr.repoFull + " #" + pr.number, pr.title, ""]
    lines.push("by " + pr.author + (pr.draft ? "  ·  draft" : ""))
    lines.push("updated " + when(pr.updatedAt))
    lines.push("created " + when(pr.createdAt))
    lines.push(pr.head + "  →  " + pr.base)
    if (pr.review) lines.push("review: " + pr.review)
    lines.push("checks: " + checkSummary(pr.checks))
    lines.push("")
    lines.push("Click for details and actions")
    return plain(lines.join("\n"))
  }

  function checkSummary(c) {
    if (!c || c.total === 0) return "none"
    var parts = []
    if (c.failing) parts.push(c.failing + " failing")
    if (c.running) parts.push(c.running + " running")
    if (c.passed) parts.push(c.passed + " passed")
    if (c.skipped) parts.push(c.skipped + " skipped")
    if (c.neutral) parts.push(c.neutral + " neutral")
    return parts.join(", ")
  }

  function titleText() {
    if (!payload) return "Pull requests"
    var parts = [payload.total + " open"]
    if (payload.failing > 0) parts.push(payload.failing + " failing")
    if (payload.running > 0) parts.push(payload.running + " running")
    return "Pull requests (" + parts.join(", ") + ")"
  }

  function tooltipText() {
    if (!payload) return reachable ? "GitHub PRs: loading" : "GitHub PRs: " + errorText
    var parts = [payload.total + (payload.total === 1 ? " open PR" : " open PRs")]
    if (payload.failing > 0) parts.push(payload.failing + " failing")
    if (payload.running > 0) parts.push(payload.running + " running")
    if (!reachable) parts.push("stale: " + errorText)
    return parts.join(", ")
  }

  // A failed refresh keeps the last good list on screen: a dropped Wi-Fi
  // connection is not a reason to forget forty PRs. The error says why it is
  // stale and how stale.
  function applyPayload(text) {
    loading = false
    root.now = Date.now()
    try {
      var data = JSON.parse(text)
      reachable = data.ok === true
      errorText = data.error || ""
      if (!reachable) return
      payload = data
      rebuildRows()
    } catch (e) {
      reachable = false
      errorText = "unexpected output from gh-prs"
    }
  }

  function errorLine() {
    var s = errorText !== "" ? errorText : "Could not reach GitHub."
    if (payload && payload.fetchedAt)
      s += "  ·  from " + ago(root.now / 1000 - payload.fetchedAt) + " ago"
    return s
  }

  // ------------------------------------------------------ the detail view

  function showDetail(pr) {
    if (!pr || pr.kind !== "pr" || !validRepo(pr.repoFull)) return
    selected = pr
    detail = null
    detailError = ""
    confirm = ""
    deleteBranch = false
    actionResult = null
    copied = false
    autoMergeSet = null
    view = "detail"
    loadDetail()
    loadSessions()
  }

  function loadSessions() {
    if (!selected) return
    sessions = []
    sessionsProc.running = false
    sessionsProc.key = selected.repoFull + "#" + selected.number
    sessionsProc.command = [root.script, "sessions", selected.repoFull, String(selected.number)]
    sessionsProc.running = true
  }

  function applySessions(text, key) {
    if (!selected || key !== selected.repoFull + "#" + selected.number) return
    try {
      var data = JSON.parse(text)
      sessions = data.ok ? (data.sessions || []) : []
    } catch (e) {
      sessions = []
    }
  }

  function validSession(s) {
    return s && (/^[A-Za-z0-9]{1,16}:[A-Za-z0-9]{1,16}$/.test(String(s.pane || ""))
      || /^https:\/\/claude\.ai\/code\/session_[A-Za-z0-9]{8,64}$/.test(String(s.url || "")))
  }

  function openSession(s) {
    if (!validSession(s)) return
    Util.execArgv([root.script, "session", s.pane || s.url])
    close()
  }

  function sessionLabel(s) {
    if (s.pane) return "Session: " + (s.title || s.pane)
    return "Session on claude.ai"
  }

  function loadDetail() {
    if (!selected) return
    detailLoading = true
    detailProc.running = false
    detailProc.command = [root.script, "detail", selected.repoFull, String(selected.number)]
    detailProc.running = true
  }

  // A reply for a PR that is no longer the one on screen is dropped: the user
  // clicked through to another while this one was loading.
  function applyDetail(text) {
    detailLoading = false
    try {
      var data = JSON.parse(text)
      if (!data.ok) { detailError = data.error || "could not load this PR"; return }
      var pr = data.pr
      if (!selected || pr.repoFull !== selected.repoFull || pr.number !== selected.number) return
      detail = pr
      detailError = ""
    } catch (e) {
      detailError = "unexpected output from gh-prs"
    }
  }

  function back() {
    if (confirm !== "") { confirm = ""; return }
    view = "list"
    selected = null
    detail = null
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // The record the detail view draws: the fetched one once it is here, the
  // list's row until then.
  readonly property var shown: detail || selected

  function mergeStateText(s) {
    if (s === "CLEAN") return "ready to merge"
    if (s === "BLOCKED") return "blocked by required reviews, checks or rules"
    if (s === "BEHIND") return "behind the base branch"
    if (s === "DIRTY") return "conflicts with the base branch"
    if (s === "UNSTABLE") return "mergeable, but a non-required check is not passing"
    if (s === "HAS_HOOKS") return "mergeable, with pre-receive hooks"
    if (s === "DRAFT") return "draft"
    return "GitHub is still working it out"
  }

  function reviewLine(d) {
    if (!d) return ""
    var parts = []
    if (d.review) parts.push(d.review)
    if (d.approvedBy && d.approvedBy.length) parts.push("approved by " + d.approvedBy.join(", "))
    if (d.changesBy && d.changesBy.length) parts.push("changes from " + d.changesBy.join(", "))
    if (d.requested && d.requested.length) parts.push("waiting on " + d.requested.join(", "))
    return parts.length ? parts.join("  ·  ") : "no reviews"
  }

  readonly property bool canMerge: !!detail && detail.open && detail.mergeBlock === ""
    && actionBusy === "" && /^[0-9a-f]{40}$/.test(detail.headSha || "")
  readonly property bool canClose: !!detail && detail.open && actionBusy === ""

  readonly property bool autoMergeOn: autoMergeSet !== null
    ? autoMergeSet
    : !!(selected && selected.autoMerge)
  readonly property bool canAutoMerge: !!detail && detail.open && !detail.draft
    && detail.mergeMethod !== "" && actionBusy === "" && !amProc.running
    && /^[0-9a-f]{40}$/.test(detail.headSha || "")

  // Turning it on pins it to the head commit on screen, as Merge does; the
  // script stops if anyone else pushes after that.
  function toggleAutoMerge() {
    if (amProc.running || !selected || !validRepo(selected.repoFull)) return
    actionResult = null
    if (autoMergeOn) {
      amProc.want = false
      amProc.command = [root.script, "automerge", "disarm", selected.repoFull, String(selected.number)]
    } else {
      if (!canAutoMerge) return
      var d = detail
      amProc.want = true
      amProc.command = [root.script, "automerge", "arm", d.repoFull, String(d.number), d.mergeMethod, d.headSha]
    }
    amProc.running = true
  }

  function applyAutoMerge(text, want) {
    try {
      var data = JSON.parse(text)
      if (data.ok) autoMergeSet = want
      else actionResult = { ok: false, text: data.error }
    } catch (e) {
      actionResult = { ok: false, text: "unexpected output from gh-prs" }
    }
    tick()
  }

  function autoMergeStatus() {
    if (!autoMergeOn) return ""
    if (autoMergeSet === true || !selected || !selected.autoMerge) return "on; it moves on the next refresh"
    return selected.autoMerge.status
  }

  function methodName(m) {
    if (m === "merge") return "merge commit"
    return m || ""
  }

  function mergeLabel() {
    if (actionBusy === "merge") return "Merging…"
    return detail && detail.mergeMethod ? "Merge (" + methodName(detail.mergeMethod) + ")" : "Merge"
  }

  // A write takes two clicks: the button only arms it, and the confirm row
  // says exactly what will happen before the second click does it.
  function armMerge() {
    if (!canMerge) return
    actionResult = null
    confirm = "merge"
  }

  function armClose() {
    if (!canClose) return
    actionResult = null
    deleteBranch = false
    confirm = "close"
  }

  // The SHA is the one the detail view showed. If the branch has moved since,
  // GitHub refuses the merge rather than taking a commit nobody looked at.
  function doMerge() {
    if (!canMerge || confirm !== "merge" || actionProc.running) return
    var d = detail
    confirm = ""
    actionBusy = "merge"
    actionProc.command = [root.script, "merge", d.repoFull, String(d.number), d.mergeMethod, d.headSha]
    actionProc.running = true
  }

  function doClose() {
    if (!canClose || confirm !== "close" || actionProc.running) return
    var d = detail
    var command = [root.script, "close", d.repoFull, String(d.number)]
    if (deleteBranch) command.push("delete-branch")
    confirm = ""
    actionBusy = "close"
    actionProc.command = command
    actionProc.running = true
  }

  function doCopy() {
    var pr = shown
    if (!pr || !validUrl(pr.url) || copyProc.running) return
    copyProc.command = [root.script, "copy", pr.url]
    copyProc.running = true
  }

  function applyAction(text) {
    actionBusy = ""
    try {
      var data = JSON.parse(text)
      actionResult = { ok: data.ok === true, text: data.ok ? data.message : data.error }
    } catch (e) {
      actionResult = { ok: false, text: "unexpected output from gh-prs" }
    }
    loadDetail()
    refresh()
  }

  // Opening the panel refreshes it, unless the list is only seconds old: a
  // refresh takes several seconds with a hundred PRs, and the one the timer
  // just finished is as good as the one this would start.
  onOpenedChanged: {
    if (opened && !(payload && Date.now() / 1000 - payload.fetchedAt < 15)) refresh()
    if (!opened) {
      cursor = -1
      view = "list"
      selected = null
      detail = null
      sessions = []
      confirm = ""
    }
  }

  // The saved sort order, read once at load.
  Process {
    id: collapsedProc
    command: [root.script, "collapsed"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: root.applyCollapsed(text)
    }
  }

  Process {
    id: sortProc
    command: [root.script, "sort"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        var m = text.trim()
        if (m === "status" || m === "date") root.sortMode = m
      }
    }
  }

  Process {
    id: tickProc
    stdout: StdioCollector {
      onStreamFinished: root.refresh()
    }
  }

  Process {
    id: amProc
    property bool want: false
    stdout: StdioCollector {
      onStreamFinished: root.applyAutoMerge(text, amProc.want)
    }
  }

  Process {
    id: sessionsProc
    property string key: ""
    stdout: StdioCollector {
      onStreamFinished: root.applySessions(text, sessionsProc.key)
    }
  }

  Process {
    id: listProc
    stdout: StdioCollector {
      onStreamFinished: root.applyPayload(text)
    }
  }

  Process {
    id: detailProc
    stdout: StdioCollector {
      onStreamFinished: root.applyDetail(text)
    }
  }

  Process {
    id: actionProc
    stdout: StdioCollector {
      onStreamFinished: root.applyAction(text)
    }
  }

  Process {
    id: copyProc
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          var data = JSON.parse(text)
          if (data.ok) { root.copied = true; copiedTimer.restart() }
          else root.actionResult = { ok: false, text: data.error }
        } catch (e) {}
      }
    }
  }

  Timer {
    id: copiedTimer
    interval: 1500
    onTriggered: root.copied = false
  }

  Timer {
    interval: root.intervalSeconds * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.tick()
  }





  // One button covers the whole widget, icon and badge, so the bar's hover,
  // tooltip and click forwarding treat it as one target. It paints nothing
  // itself: the icon is drawn in a standard slot at the start, with the same
  // optical sizing the built-in widgets get, and the badge fills what it
  // added, after the icon on a horizontal bar and below it on a vertical one.
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    opacity: root.reachable ? 1 : 0.5
    slotSize: root.barSlot
    hasVisualContent: true
    tooltipText: root.plain(root.tooltipText())

    Item {
      id: iconSlot
      x: !root.vertical && LayoutMirroring.enabled ? root.width - width : 0
      width: root.vertical ? root.width : Style.bar.iconSlot
      height: root.vertical ? Style.bar.iconSlot : root.height

      OpticalGlyph {
        anchors.centerIn: parent
        width: button.canvasSize
        height: button.canvasSize
        text: root.iconPr
        fontFamily: root.fontFamily
        fontSize: Style.bar.iconFont
        paintedSize: Style.bar.iconSize
        // The bar marks an open panel itself, as it does for every widget.
        color: button.foreground
      }
    }

    // Red when anything counted is failing, the running colour when the
    // count is only checks still going.
    Rectangle {
      visible: root.badgeCount > 0
      height: root.badgeHeight
      width: root.badgeWidth
      radius: height / 2
      color: root.badgeAlarm ? root.urgent : root.running
      x: root.vertical
        ? (root.width - width) / 2
        : (LayoutMirroring.enabled ? root.width - root.badgeStart - width : root.badgeStart)
      y: root.vertical ? root.badgeStart : (root.height - height) / 2

      Text {
        anchors.centerIn: parent
        text: root.badgeCount
        textFormat: Text.PlainText
        font.family: root.fontFamily
        font.pixelSize: root.badgeFont
        font.bold: true
        renderType: Text.NativeRendering
        color: Color.background
      }
    }

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    // Escape steps back one level: out of a confirm, then out of the detail
    // view, and only then closes the panel. Clicking outside closes it from
    // anywhere.
    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.view === "detail" ? root.back() : root.close()
      onMoveRequested: function(dx, dy) {
        if (root.view === "list" && dy !== 0) root.moveCursor(dy)
        else if (root.view === "detail" && dx < 0) root.back()
      }
      // PanelKeyCatcher hands `x` to deleteRequested rather than textKey.
      onDeleteRequested: if (root.view === "detail") root.armClose()
      onActivateRequested: {
        if (root.view !== "list" || root.cursor < 0 || root.cursor >= root.rows.length) return
        var r = root.rows[root.cursor]
        if (r.kind === "repo") root.toggleCollapsed(r.repo)
        else root.showDetail(r)
      }
      onTextKey: function(t) {
        if (t === "r") { root.refresh(); if (root.view === "detail") root.loadDetail() }
        else if (t === "o") {
          if (root.view === "detail") root.openPr(root.shown)
          else if (root.isPr(root.cursor)) root.openPr(root.rows[root.cursor])
        }
        else if (t === "c" && root.view === "detail") root.doCopy()
        // These only arm the action and show what it will do; the confirm
        // itself is a click, so no run of keystrokes can merge or close.
        else if (t === "m" && root.view === "detail") root.armMerge()
        else if (t === "s" && root.view === "list") root.setSort(root.sortMode === "status" ? "date" : "status")
      }

      Column {
        id: content
        anchors.fill: parent
        spacing: Style.space(6)

        // ------------------------------------------------------- header

        Item {
          width: parent.width
          height: Math.max(header.implicitHeight, sortSwitch.implicitHeight)

        PanelSectionHeader {
          id: header
          anchors.left: parent.left
          anchors.right: sortSwitch.visible ? sortSwitch.left : parent.right
          anchors.rightMargin: sortSwitch.visible ? Style.space(8) : 0
          anchors.verticalCenter: parent.verticalCenter
          text: root.view === "detail" && root.shown
            ? root.shown.repoFull + " #" + root.shown.number
            : root.titleText() + (root.loading ? "  …" : "")
          textFormat: Text.PlainText
          elide: Text.ElideRight
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        // Two states, both always visible, so it reads as "which order" and
        // not as a button that does something.
        Row {
          id: sortSwitch
          visible: root.view === "list"
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          spacing: Style.space(2)

          Repeater {
            model: [{ mode: "status", label: "By status" }, { mode: "date", label: "By date" }]

            Button {
              required property var modelData
              text: modelData.label
              selected: root.sortMode === modelData.mode
              bordered: root.sortMode === modelData.mode
              fontSize: Style.font.caption
              verticalPadding: Style.space(1)
              foreground: root.sortMode === modelData.mode ? root.foreground : root.quiet
              fontFamily: root.fontFamily
              tooltipText: "Sort " + modelData.label.toLowerCase() + " (s)"
              onClicked: root.setSort(modelData.mode)
            }
          }
        }
        }

        PanelSeparator { width: parent.width }

        Item {
          width: parent.width
          height: !root.reachable && root.view === "list" ? staleWarning.implicitHeight + Style.space(6) : 0
          visible: height > 0

          Text {
            id: staleWarning
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            text: root.errorLine()
            textFormat: Text.PlainText
            elide: Text.ElideRight
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.urgent
          }
        }

        // --------------------------------------------------------- list

        ListView {
          id: list
          width: parent.width
          visible: root.view === "list" && root.rows.length > 0
          clip: true
          model: root.rows
          spacing: Style.space(1)
          boundsBehavior: Flickable.StopAtBounds
          flickableDirection: Flickable.VerticalFlick
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          readonly property int cap: {
            var chrome = Style.space(80)
            if (!root.reachable) chrome += Style.space(24)
            return Math.max(Style.space(140),
                            panel.availableCardHeight - panel.verticalContentInset - chrome)
          }
          height: visible ? Math.min(contentHeight, cap) : 0

          delegate: Item {
            id: row
            required property var modelData
            required property int index

            readonly property bool isHeading: modelData.kind === "repo"
            readonly property bool active: root.cursor === row.index || rowMouse.containsMouse
            readonly property bool isStale: !isHeading && root.stale(modelData)

            width: list.width - (list.interactive ? Style.space(10) : 0)
            height: isHeading
              ? headingLabel.implicitHeight + Style.space(row.index === 0 ? 4 : 10)
              : prContent.implicitHeight + Style.space(10)

            // Repository heading: a fold arrow, owner/name, and how many PRs
            // sit under it; folded, also how many of them are failing, since
            // their rows are not there to say so. Click or Enter folds it.
            Text {
              id: headingLabel
              visible: row.isHeading
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.bottom: parent.bottom
              anchors.leftMargin: Style.space(6)
              text: row.isHeading
                ? (row.modelData.collapsed ? "\u25B8  " : "\u25BE  ") + row.modelData.repo + "  ·  " + row.modelData.count
                  + (row.modelData.collapsed && row.modelData.failing > 0 ? "  ·  " + row.modelData.failing + " failing" : "")
                : ""
              textFormat: Text.PlainText
              elide: Text.ElideRight
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              color: Qt.darker(root.foreground, 1.5)
            }

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: row.active
                ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08)
                : "transparent"

              Behavior on color { ColorAnimation { duration: 80 } }
            }

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              acceptedButtons: Qt.LeftButton | Qt.MiddleButton
              onContainsMouseChanged: if (containsMouse) root.cursor = row.index
              // Middle click goes straight to the browser, the way it would
              // on a link.
              onClicked: function(mouse) {
                if (row.isHeading) { if (mouse.button === Qt.LeftButton) root.toggleCollapsed(row.modelData.repo) }
                else if (mouse.button === Qt.MiddleButton) root.openPr(row.modelData)
                else root.showDetail(row.modelData)
              }
            }

            PanelToolTip {
              visible: rowMouse.containsMouse && !row.isHeading && root.view === "list"
              text: root.summaryText(row.modelData)
              fontFamily: root.fontFamily
            }

            // Drafts and stale PRs are drawn at reduced strength: one you
            // have said is not ready, the other nobody has touched in weeks.
            // The hovered row comes back up so it can be read.
            Row {
              id: prContent
              visible: !row.isHeading
              opacity: row.active ? 1
                : row.modelData.draft ? 0.5
                : row.isStale ? 0.6 : 1
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(6)
              anchors.rightMargin: Style.space(6)
              spacing: Style.space(7)

              Item {
                width: Style.space(14)
                height: Style.space(14)
                anchors.top: parent.top
                anchors.topMargin: Style.space(1)

                Text {
                  anchors.centerIn: parent
                  text: root.iconDot
                  textFormat: Text.PlainText
                  font.family: root.fontFamily
                  font.pixelSize: Style.space(7)
                  color: root.stateColor(row.modelData.state)
                }
              }

              Column {
                width: parent.width - Style.space(14) - prContent.spacing
                spacing: Style.space(2)

                Item {
                  width: parent.width
                  height: title.implicitHeight

                  Text {
                    id: title
                    anchors.left: parent.left
                    anchors.right: status.left
                    anchors.rightMargin: Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                    text: row.isHeading ? "" : row.modelData.title
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    color: row.active ? root.foreground : Qt.darker(root.foreground, 1.15)
                  }

                  Text {
                    id: status
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: row.isHeading ? "" : row.modelData.label
                    textFormat: Text.PlainText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: row.modelData.state === "failing"
                    color: root.stateColor(row.modelData.state)
                  }
                }

                Item {
                  width: parent.width
                  height: subtitle.implicitHeight

                  Text {
                    id: subtitle
                    anchors.left: parent.left
                    anchors.right: reviewText.left
                    anchors.rightMargin: Style.space(8)
                    text: row.isHeading ? "" : root.subtitleFor(row.modelData)
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.quiet
                  }

                  // Review decision, then the age, so the right edge of
                  // every row ends with how long since it moved.
                  Row {
                    id: reviewText
                    anchors.right: parent.right
                    spacing: Style.space(8)

                    Text {
                      visible: text !== ""
                      text: row.isHeading ? "" : (row.modelData.review || "")
                      textFormat: Text.PlainText
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      color: root.reviewColor(row.modelData.review)
                    }

                    Text {
                      text: row.isHeading ? "" : root.ageLabel(row.modelData)
                      textFormat: Text.PlainText
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.italic: row.isStale
                      color: row.isStale ? root.running : root.quiet
                    }
                  }
                }
              }
            }
          }
        }

        // -------------------------------------------------------- empty

        Item {
          width: parent.width
          height: root.view === "list" && root.rows.length === 0 && root.reachable
            ? empty.implicitHeight + Style.space(16) : 0
          visible: height > 0

          Text {
            id: empty
            anchors.centerIn: parent
            width: parent.width
            horizontalAlignment: Text.AlignHCenter
            text: root.payload ? "No open pull requests" : "Loading…"
            textFormat: Text.PlainText
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: Qt.darker(root.foreground, 1.8)
          }
        }

        // ------------------------------------------------------- detail

        Flickable {
          id: detailFlick
          width: parent.width
          visible: root.view === "detail" && !!root.shown
          clip: true
          contentWidth: width
          contentHeight: detailColumn.implicitHeight
          boundsBehavior: Flickable.StopAtBounds
          interactive: contentHeight > height
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }
          height: visible
            ? Math.min(contentHeight,
                       Math.max(Style.space(140),
                                panel.availableCardHeight - panel.verticalContentInset - Style.space(60)))
            : 0

          Column {
            id: detailColumn
            width: detailFlick.width - (detailFlick.interactive ? Style.space(10) : 0)
            spacing: Style.space(8)

            Text {
              width: parent.width
              text: root.shown ? root.shown.title : ""
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              color: root.foreground
            }

            // Label / value pairs, one per line, labels in one column.
            Column {
              width: parent.width
              spacing: Style.space(3)

              Repeater {
                model: {
                  var s = root.shown
                  if (!s) return []
                  var d = root.detail
                  var out = [
                    ["author", s.author + (s.draft ? "  ·  draft" : "")],
                    ["updated", root.when(s.updatedAt)],
                    ["created", root.when(s.createdAt)],
                    ["branch", s.head + "  →  " + s.base
                               + (d && d.headSha ? "  ·  " + d.headSha.substring(0, 7) : "")],
                    ["review", d ? root.reviewLine(d) : (s.review || "…")]
                  ]
                  if (d) out.push(["merge", d.open
                    ? d.mergeState + ": " + root.mergeStateText(d.mergeState)
                    : d.prState.toLowerCase()])
                  return out
                }

                Row {
                  required property var modelData
                  width: parent.width
                  spacing: Style.space(8)

                  Text {
                    width: Style.space(56)
                    text: modelData[0]
                    textFormat: Text.PlainText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.quiet
                  }

                  Text {
                    width: parent.width - Style.space(64)
                    text: modelData[1]
                    textFormat: Text.PlainText
                    wrapMode: Text.Wrap
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.foreground
                  }
                }
              }
            }

            PanelSeparator { width: parent.width }

            // Checks: what is failing by name first, then what is still
            // running, then a count of everything that is fine.
            Text {
              width: parent.width
              text: root.shown ? "Checks  ·  " + root.shown.checks.label : ""
              textFormat: Text.PlainText
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              color: root.shown ? root.stateColor(root.shown.checks.state) : root.foreground
            }

            Column {
              width: parent.width
              spacing: Style.space(2)
              visible: !!root.detail

              Repeater {
                model: root.detail
                  ? root.detail.failingNames.map(function(n) { return { name: n, state: "failing" } })
                      .concat(root.detail.runningNames.map(function(n) { return { name: n, state: "running" } }))
                  : []

                Row {
                  required property var modelData
                  width: parent.width
                  spacing: Style.space(6)

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    text: root.iconDot
                    textFormat: Text.PlainText
                    font.family: root.fontFamily
                    font.pixelSize: Style.space(5)
                    color: root.stateColor(modelData.state)
                  }

                  Text {
                    width: parent.width - Style.space(70)
                    text: modelData.name
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.foreground
                  }

                  Text {
                    text: modelData.state
                    textFormat: Text.PlainText
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    color: root.stateColor(modelData.state)
                  }
                }
              }

              Text {
                width: parent.width
                text: {
                  var d = root.detail
                  if (!d) return ""
                  var c = d.checks, parts = []
                  if (c.passed) parts.push(c.passed + " passed")
                  if (c.skipped) parts.push(c.skipped + " skipped")
                  if (c.neutral) parts.push(c.neutral + " neutral")
                  var s = parts.join(", ")
                  if (d.listedChecks < c.total)
                    s += (s ? "  ·  " : "") + "names shown for the first "
                      + d.listedChecks + " of " + c.total
                  return s
                }
                visible: text !== ""
                textFormat: Text.PlainText
                wrapMode: Text.Wrap
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.quiet
              }
            }

            Text {
              width: parent.width
              visible: root.detailLoading || root.detailError !== ""
              text: root.detailError !== "" ? root.detailError : "Loading checks and reviews…"
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: root.detailError !== "" ? root.urgent : root.quiet
            }

            PanelSeparator { width: parent.width }

            // ----------------------------------------------- actions

            Flow {
              width: parent.width
              spacing: Style.space(6)

              Button {
                text: "Back"
                bordered: true
                fontSize: Style.font.caption
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.back()
              }

              Button {
                text: "Open"
                bordered: true
                fontSize: Style.font.caption
                foreground: root.foreground
                fontFamily: root.fontFamily
                tooltipText: "Open in the browser (o)"
                onClicked: root.openPr(root.shown)
              }

              // The session that made the PR: its Herdr pane, or claude.ai.
              Repeater {
                model: root.sessions.filter(root.validSession).slice(0, 3)

                Button {
                  required property var modelData
                  text: root.sessionLabel(modelData)
                  bordered: true
                  fontSize: Style.font.caption
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  tooltipText: modelData.pane
                    ? "Switch Herdr to this session (" + (modelData.status || "unknown") + ")"
                    : "Open " + modelData.url
                  onClicked: root.openSession(modelData)
                }
              }

              Button {
                text: root.copied ? "Copied" : "Copy link"
                bordered: true
                fontSize: Style.font.caption
                foreground: root.copied ? root.passing : root.foreground
                fontFamily: root.fontFamily
                tooltipText: "Copy the PR's URL (c)"
                onClicked: root.doCopy()
              }

              Button {
                text: root.mergeLabel()
                bordered: true
                enabled: root.canMerge
                opacity: enabled ? 1 : 0.4
                selected: root.confirm === "merge"
                fontSize: Style.font.caption
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.armMerge()
              }

              Button {
                text: root.actionBusy === "close" ? "Closing…" : "Close PR"
                bordered: true
                enabled: root.canClose
                opacity: enabled ? 1 : 0.4
                selected: root.confirm === "close"
                fontSize: Style.font.caption
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.armClose()
              }
            }

            // Auto-merge: on, it merges once checks pass, rebasing onto the
            // base whenever the repository says the branch is behind.
            Toggle {
              width: parent.width
              visible: !!root.detail && (root.detail.open || root.autoMergeOn)
              enabled: root.autoMergeOn || root.canAutoMerge
              opacity: enabled ? 1 : 0.4
              label: "Auto-merge"
                + (root.detail && root.detail.mergeMethod ? " (" + root.methodName(root.detail.mergeMethod) + ")" : "")
                + " when checks pass, rebasing when behind"
              checked: root.autoMergeOn
              titleSize: Style.font.caption
              foreground: root.foreground
              fontFamily: root.fontFamily
              onClicked: root.toggleAutoMerge()
            }

            Text {
              width: parent.width
              visible: root.autoMergeOn
              text: "Auto-merge: " + root.autoMergeStatus()
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: root.running
            }

            // Why Merge is off, in the panel's words and then GitHub's.
            Text {
              width: parent.width
              visible: !!root.detail && root.detail.mergeBlock !== "" && root.confirm === ""
              text: root.detail
                ? "Merge unavailable: " + root.detail.mergeBlock
                  + (root.detail.open ? "  (" + root.detail.mergeState + ")" : "")
                : ""
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: root.quiet
            }

            // ----------------------------------------------- confirm

            Rectangle {
              width: parent.width
              visible: root.confirm !== ""
              height: visible ? confirmColumn.implicitHeight + Style.space(12) : 0
              radius: Style.cornerRadius
              color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.10)
              border.width: 1
              border.color: Qt.rgba(root.urgent.r, root.urgent.g, root.urgent.b, 0.5)

              Column {
                id: confirmColumn
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Style.space(6)
                spacing: Style.space(6)

                Text {
                  width: parent.width
                  text: {
                    var d = root.detail
                    if (!d) return ""
                    if (root.confirm === "merge")
                      return "Merge " + d.repoFull + "#" + d.number + " into " + d.base
                        + " by " + root.methodName(d.mergeMethod) + ", at head " + d.headSha.substring(0, 7) + "?"
                    return "Close " + d.repoFull + "#" + d.number + " without merging?\n“"
                      + d.title + "”"
                  }
                  textFormat: Text.PlainText
                  wrapMode: Text.Wrap
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.foreground
                }

                Toggle {
                  width: parent.width
                  visible: root.confirm === "close"
                  label: "Also delete the branch " + (root.detail ? root.detail.head : "")
                  checked: root.deleteBranch
                  titleSize: Style.font.caption
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  onClicked: root.deleteBranch = !root.deleteBranch
                }

                Row {
                  spacing: Style.space(6)

                  Button {
                    text: "Cancel"
                    bordered: true
                    fontSize: Style.font.caption
                    foreground: root.foreground
                    fontFamily: root.fontFamily
                    onClicked: root.confirm = ""
                  }

                  Button {
                    text: root.confirm === "merge" ? "Confirm merge" : "Confirm close"
                    bordered: true
                    fontSize: Style.font.caption
                    foreground: root.urgent
                    fontFamily: root.fontFamily
                    onClicked: root.confirm === "merge" ? root.doMerge() : root.doClose()
                  }
                }
              }
            }

            Text {
              width: parent.width
              visible: !!root.actionResult
              text: root.actionResult ? root.actionResult.text : ""
              textFormat: Text.PlainText
              wrapMode: Text.Wrap
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              color: root.actionResult && root.actionResult.ok ? root.passing : root.urgent
            }
          }
        }
      }
    }
  }
}
