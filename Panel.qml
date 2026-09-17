import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Kubarchy: pick a kubeconfig + cluster, browse namespaces (as a horizontal
// pill bar) and pods/deployments (as a side-menu switched list), then drill
// into a pod for logs / resolved env / per-container metrics. Everything is
// read-only kubectl underneath — no client library, three-ish `kubectl`
// invocations per screen, all routed through `bash -c '... 2>&1'` (see
// runShell below for why).
Panel {
  id: root
  moduleName: "xengine.kubarchy"
  ipcTarget: "xengine.kubarchy"

  property var anchorItem: null
  property var hostWidget: null
  readonly property var barIdentity: hostWidget || root

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family

  // ---- column widths, shared between header rows and data rows ----
  readonly property int colStatusDot: Style.space(12)
  readonly property int colCpu: Style.space(48)
  readonly property int colMem: Style.space(58)
  readonly property int colRestarts: Style.space(64)
  readonly property int colControlledBy: Style.space(150)
  readonly property int colAge: Style.space(48)
  readonly property int colReady: Style.space(56)
  readonly property int colUpToDate: Style.space(84)
  readonly property int colAvailable: Style.space(76)
  readonly property int sideMenuWidth: Style.space(110)

  // ---- top-level flow: cluster picker -> namespace/resource browser -> pod detail ----
  property bool initialized: false
  property string kubeconfigInput: "~/.kube/config"
  property string kubeconfigPath: ""
  property bool browsingKubeconfig: false
  property string browseDir: ""
  property var browseEntries: []

  property var contexts: []          // [{name, current}]
  property string selectedContext: ""

  property string resourceType: "pods"   // "pods" | "deployments"
  property var namespaces: []            // string[]
  property string selectedNamespace: ""  // "" == all namespaces
  property var pods: []                  // [{name, namespace, status, restarts, controlledBy, age, containers, cpu, mem}]
  property var deployments: []           // [{name, namespace, ready, upToDate, available, age}]

  // Detail is one panel with three sections shown at once (logs, resolved
  // env, per-container metrics) rather than tabs, so each fetch/loading/
  // error is tracked independently instead of sharing one flag.
  property var detailPod: null
  property string logsText: ""
  property var envList: []               // [{key, value}]
  property var metricsContainers: []     // [{name, cpu, mem}]
  property var metricsHistory: []        // [{t, cpu (millicores), mem (Mi)}], newest last, pod-level sum
  // Sticks to the newest log line as refreshes bring more in; turns off the
  // moment the user scrolls up to read history, back on once they scroll
  // back down to the end themselves.
  property bool autoScrollLogs: true

  property bool contextsLoading: false
  property bool namespacesLoading: false
  property bool listLoading: false
  property bool logsLoading: false
  property bool envLoading: false
  property bool metricsLoading: false
  property string errorText: ""
  property string logsError: ""
  property string envError: ""
  property string metricsError: ""
  property string metricsNote: ""

  readonly property string screen: root.detailPod !== null ? "detail" : (root.selectedContext === "" ? "cluster" : "main")

  // ---- lifecycle ----
  function open() {
    root.controller.show()
    if (!root.initialized) {
      root.initialized = true
      var homeDir = Quickshell.env("HOME")
      var savedPath = root.setting("kubeconfigPath", "")
      root.kubeconfigPath = savedPath ? savedPath : Model.expandHome("~/.kube/config", homeDir)
      root.kubeconfigInput = root.kubeconfigPath
      var savedContext = root.setting("selectedContext", "")
      if (savedContext) {
        root.selectedContext = savedContext
        root.fetchNamespaces()
      } else {
        root.fetchContexts()
      }
    } else {
      root.refresh()
    }
  }

  function close() { root.controller.hide() }
  function toggle() { if (root.opened) root.close(); else root.open() }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.barIdentity, direction)
    return false
  }

  function refresh() {
    if (root.detailPod) {
      root.fetchLogs()
      root.fetchEnv()
      root.fetchMetrics()
    } else if (root.selectedContext) {
      root.fetchList()
    } else {
      root.fetchContexts()
    }
  }

  function persistSettings(values) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    for (var key in values) entry[key] = values[key]
    root.settings = entry
    if (root.hostWidget && "settings" in root.hostWidget) root.hostWidget.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function")
      root.bar.shell.updateEntryInline(root.moduleName, entry)
  }

  // Every kubectl call runs through `bash -c '... 2>&1'` instead of a bare
  // argv array: if the binary named in argv[0] doesn't exist, Process never
  // starts (no stdout/stderr, no onExited), and the UI spins forever. Bash
  // is always present, so the process always starts and always exits, and a
  // missing kubectl becomes ordinary command output instead of a silent
  // hang. Each proc is stopped before being reused so the most recent click
  // always wins over a slower in-flight request.
  function runShell(proc, script) {
    if (proc.running) proc.running = false
    proc.command = ["bash", "-c", script]
    proc.running = true
  }

  function kubectlBase() {
    var s = "kubectl"
    if (root.kubeconfigPath) s += " --kubeconfig " + Model.shq(root.kubeconfigPath)
    if (root.selectedContext) s += " --context " + Model.shq(root.selectedContext)
    return s
  }

  // ---- kubeconfig file browser ----
  function toggleBrowse() {
    root.browsingKubeconfig = !root.browsingKubeconfig
    if (root.browsingKubeconfig) {
      var start = root.browseDir || Quickshell.env("HOME")
      root.listDir(start)
    }
  }

  function listDir(dir) {
    root.browseDir = dir
    root.runShell(browseProc, "ls -1ap -- " + Model.shq(dir) + " 2>&1")
  }

  function navigateEntry(entry) {
    if (entry.isDir) root.listDir(Model.joinPath(root.browseDir, entry.name))
    else { root.kubeconfigInput = Model.joinPath(root.browseDir, entry.name); root.browsingKubeconfig = false }
  }

  function navigateUp() { root.listDir(Model.parentPath(root.browseDir)) }

  function loadKubeconfig() {
    var homeDir = Quickshell.env("HOME")
    var expanded = Model.expandHome((root.kubeconfigInput || "").trim() || "~/.kube/config", homeDir)
    root.kubeconfigPath = expanded
    root.kubeconfigInput = expanded
    root.selectedContext = ""
    root.contexts = []
    root.browsingKubeconfig = false
    root.persistSettings({ kubeconfigPath: expanded, selectedContext: "" })
    root.fetchContexts()
  }

  // ---- cluster (context) selection ----
  function fetchContexts() {
    root.errorText = ""
    root.contextsLoading = true
    var path = root.kubeconfigPath || Model.expandHome("~/.kube/config", Quickshell.env("HOME"))
    root.runShell(contextsProc,
      "kubectl --kubeconfig " + Model.shq(path) + " config get-contexts -o name 2>&1; "
      + "echo __CURRENT__; kubectl --kubeconfig " + Model.shq(path) + " config current-context 2>&1")
  }

  function connectCluster(name) {
    root.selectedContext = name
    root.namespaces = []
    root.selectedNamespace = ""
    root.pods = []
    root.deployments = []
    root.errorText = ""
    root.persistSettings({ selectedContext: name, kubeconfigPath: root.kubeconfigPath })
    root.fetchNamespaces()
  }

  function disconnect() {
    root.selectedContext = ""
    root.namespaces = []
    root.pods = []
    root.deployments = []
    root.detailPod = null
    root.errorText = ""
    root.persistSettings({ selectedContext: "" })
    root.fetchContexts()
  }

  // ---- namespaces + resource lists ----
  function fetchNamespaces() {
    root.errorText = ""
    root.namespacesLoading = true
    root.runShell(nsProc, root.kubectlBase() + " get namespaces --no-headers -o custom-columns=:metadata.name 2>&1")
  }

  function fetchList() {
    if (root.resourceType === "pods") root.fetchPods()
    else root.fetchDeployments()
  }

  function selectNamespace(ns) {
    if (ns === root.selectedNamespace) return
    root.selectedNamespace = ns
    root.fetchList()
  }

  function selectResourceType(type) {
    if (type === root.resourceType) return
    root.resourceType = type
    root.fetchList()
  }

  function nsFlag() {
    return root.selectedNamespace === "" ? "-A" : ("-n " + Model.shq(root.selectedNamespace))
  }

  function fetchPods() {
    root.errorText = ""
    root.listLoading = true
    root.runShell(podsProc, root.kubectlBase() + " get pods " + root.nsFlag() + " -o json 2>&1")
  }

  function fetchTop() {
    root.metricsNote = ""
    root.runShell(topProc, root.kubectlBase() + " top pods " + root.nsFlag() + " 2>&1")
  }

  function fetchDeployments() {
    root.errorText = ""
    root.listLoading = true
    root.runShell(deploymentsProc, root.kubectlBase() + " get deployments " + root.nsFlag() + " -o json 2>&1")
  }

  function statusColor(status) {
    var s = String(status || "").toLowerCase()
    if (s.indexOf("running") >= 0 || s.indexOf("succeeded") >= 0) return Color.accent
    if (s.indexOf("pending") >= 0 || s.indexOf("containercreating") >= 0) return Color.muted
    return Color.urgent
  }

  // ---- pod detail: logs, env and metrics fetch together and render as
  // three simultaneous panes rather than tabs (see the detail-screen UI). ----
  function openDetail(pod) {
    root.detailPod = pod
    root.logsText = ""
    root.envList = []
    root.metricsContainers = []
    root.metricsHistory = []
    root.logsError = ""
    root.envError = ""
    root.metricsError = ""
    root.autoScrollLogs = true
    root.fetchLogs()
    root.fetchEnv()
    root.fetchMetrics()
  }

  function closeDetail() { root.detailPod = null }

  function fetchLogs() {
    if (!root.detailPod) return
    root.logsLoading = true
    root.logsError = ""
    root.runShell(logsProc, root.kubectlBase() + " logs " + Model.shq(root.detailPod.name)
      + " -n " + Model.shq(root.detailPod.namespace) + " --tail=300 --all-containers=true --timestamps 2>&1")
  }

  function fetchEnv() {
    if (!root.detailPod) return
    root.envLoading = true
    root.envError = ""
    var containers = root.detailPod.containers || []
    var containerFlag = containers.length > 0 ? (" -c " + Model.shq(containers[0])) : ""
    root.runShell(envProc, root.kubectlBase() + " exec " + Model.shq(root.detailPod.name)
      + " -n " + Model.shq(root.detailPod.namespace) + containerFlag + " -- env 2>&1")
  }

  function fetchMetrics() {
    if (!root.detailPod) return
    root.metricsLoading = true
    root.metricsError = ""
    root.runShell(metricsProc, root.kubectlBase() + " top pod " + Model.shq(root.detailPod.name)
      + " -n " + Model.shq(root.detailPod.namespace) + " --containers 2>&1")
  }

  // ---- processes ----
  Process {
    id: contextsProc
    stdout: StdioCollector { id: contextsOut; waitForEnd: true }
    onExited: function (exitCode) {
      root.contextsLoading = false
      var full = String(contextsOut.text || "")
      var marker = "__CURRENT__"
      var idx = full.indexOf(marker)
      var listPart = idx >= 0 ? full.substring(0, idx) : full
      var currentPart = idx >= 0 ? full.substring(idx + marker.length) : ""
      var current = currentPart.trim().split("\n")[0] || ""
      var parsed = Model.parseContexts(listPart, current)
      root.contexts = parsed
      root.errorText = parsed.length === 0 ? (listPart.trim() || "No clusters found") : ""
    }
    onRunningChanged: if (!running) root.contextsLoading = false
  }

  Process {
    id: browseProc
    stdout: StdioCollector { id: browseOut; waitForEnd: true }
    onExited: function (exitCode) {
      root.browseEntries = exitCode === 0 ? Model.parseDirListing(browseOut.text) : []
    }
  }

  Process {
    id: nsProc
    stdout: StdioCollector { id: nsOut; waitForEnd: true }
    onExited: function (exitCode) {
      root.namespacesLoading = false
      if (exitCode !== 0) {
        root.errorText = String(nsOut.text || "").trim() || ("kubectl exited with code " + exitCode)
        root.namespaces = []
        return
      }
      root.namespaces = Model.parseNamespaces(nsOut.text)
      root.fetchList()
    }
    onRunningChanged: if (!running) root.namespacesLoading = false
  }

  Process {
    id: podsProc
    stdout: StdioCollector { id: podsOut; waitForEnd: true }
    onExited: function (exitCode) {
      root.listLoading = false
      if (exitCode !== 0) {
        root.errorText = String(podsOut.text || "").trim() || ("kubectl exited with code " + exitCode)
        root.pods = []
        return
      }
      root.pods = Model.parsePodsJson(podsOut.text)
      root.fetchTop()
    }
    onRunningChanged: if (!running) root.listLoading = false
  }

  Process {
    id: topProc
    stdout: StdioCollector { id: topOut; waitForEnd: true }
    onExited: function (exitCode) {
      if (exitCode !== 0) { root.metricsNote = "Pod CPU/memory unavailable (metrics-server not installed?)"; return }
      root.pods = Model.mergeTop(root.pods, Model.parseTopText(topOut.text, root.selectedNamespace === ""), root.selectedNamespace === "")
    }
  }

  Process {
    id: deploymentsProc
    stdout: StdioCollector { id: depOut; waitForEnd: true }
    onExited: function (exitCode) {
      root.listLoading = false
      if (exitCode !== 0) {
        root.errorText = String(depOut.text || "").trim() || ("kubectl exited with code " + exitCode)
        root.deployments = []
        return
      }
      root.deployments = Model.parseDeploymentsJson(depOut.text)
    }
    onRunningChanged: if (!running) root.listLoading = false
  }

  Process {
    id: logsProc
    stdout: StdioCollector { id: logsOut; waitForEnd: true }
    onExited: function (exitCode) {
      root.logsLoading = false
      root.logsText = String(logsOut.text || "")
      if (exitCode !== 0 && root.logsText === "") root.logsError = "kubectl exited with code " + exitCode
    }
    onRunningChanged: if (!running) root.logsLoading = false
  }

  Process {
    id: envProc
    stdout: StdioCollector { id: envOut; waitForEnd: true }
    onExited: function (exitCode) {
      root.envLoading = false
      if (exitCode !== 0) {
        root.envError = String(envOut.text || "").trim() || ("kubectl exited with code " + exitCode)
        root.envList = []
        return
      }
      root.envList = Model.parseEnvText(envOut.text)
    }
    onRunningChanged: if (!running) root.envLoading = false
  }

  Process {
    id: metricsProc
    stdout: StdioCollector { id: metricsOut; waitForEnd: true }
    onExited: function (exitCode) {
      root.metricsLoading = false
      if (exitCode !== 0) {
        root.metricsError = String(metricsOut.text || "").trim() || "Pod metrics unavailable (metrics-server not installed?)"
        root.metricsContainers = []
        return
      }
      var containers = Model.parseTopContainers(metricsOut.text)
      root.metricsContainers = containers
      var cpu = Model.sumContainerCpu(containers)
      var mem = Model.sumContainerMem(containers)
      if (cpu !== null || mem !== null) {
        var hist = root.metricsHistory.slice()
        hist.push({ t: Date.now(), cpu: cpu || 0, mem: mem || 0 })
        if (hist.length > 30) hist = hist.slice(hist.length - 30)
        root.metricsHistory = hist
      }
    }
    onRunningChanged: if (!running) root.metricsLoading = false
  }

  // Light auto-refresh while the panel is open.
  Timer {
    interval: 15000
    running: root.opened
    repeat: true
    onTriggered: root.refresh()
  }

  PopupCard {
    id: card
    anchorItem: root.anchorItem
    bar: root.bar
    owner: root.barIdentity
    open: root.opened
    contentWidth: card.fittedContentWidth(Style.space(780))
    // Not routed through fittedContentHeight()/availableCardHeight: on a
    // replacement bar whose anchor window reports a much taller window than
    // its visual strip (observed with a third-party full-bar plugin here),
    // availableCardHeight collapses to its 120px floor and the popup
    // renders as a sliver. screenH itself stays reliable, so size off that
    // directly instead.
    contentHeight: Math.min(Style.space(540), Math.max(Style.space(300), card.screenH > 0 ? card.screenH - Style.space(160) : Style.space(540)))

    Item {
      anchors.fill: parent

      // ---- header ----
      RowLayout {
        id: headerRow
        width: parent.width
        height: Style.spacing.controlHeight
        spacing: Style.spacing.sm

        Text {
          visible: root.screen !== "cluster"
          text: "←"
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.title

          MouseArea {
            anchors.fill: parent
            anchors.margins: -Style.spacing.sm
            cursorShape: Qt.PointingHandCursor
            onClicked: root.screen === "detail" ? root.closeDetail() : root.disconnect()
          }
        }

        Text {
          Layout.fillWidth: true
          text: root.screen === "detail" ? root.detailPod.name
            : root.screen === "cluster" ? "Kubarchy"
            : root.selectedContext
          color: root.contentForeground
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.title
          font.bold: true
          elide: Text.ElideMiddle
        }

        Text {
          visible: root.screen === "detail"
          text: root.detailPod ? root.detailPod.namespace : ""
          color: Qt.darker(root.contentForeground, 1.3)
          font.family: root.contentFontFamily
          font.pixelSize: Style.font.bodySmall
        }

        Button {
          visible: root.screen === "cluster"
          text: root.browsingKubeconfig ? "Hide browser" : "Browse config"
          fontSize: Style.font.bodySmall
          bordered: true
          onClicked: root.toggleBrowse()
        }

        Button {
          text: (root.contextsLoading || root.namespacesLoading || root.listLoading || root.logsLoading || root.envLoading || root.metricsLoading) ? "Loading…" : "Refresh"
          fontSize: Style.font.bodySmall
          bordered: true
          onClicked: root.refresh()
        }
      }

      Text {
        id: errorLabel
        visible: root.errorText !== ""
        anchors.top: headerRow.bottom
        anchors.topMargin: Style.spacing.xs
        width: parent.width
        text: root.errorText
        color: Color.urgent
        wrapMode: Text.Wrap
        font.family: root.contentFontFamily
        font.pixelSize: Style.font.bodySmall
      }

      Item {
        id: body
        anchors.top: root.errorText !== "" ? errorLabel.bottom : headerRow.bottom
        anchors.topMargin: Style.spacing.md
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.bottom: parent.bottom

        // ================= CLUSTER SCREEN =================
        Column {
          anchors.fill: parent
          visible: root.screen === "cluster"
          spacing: Style.spacing.md

          Row {
            width: parent.width
            spacing: Style.spacing.sm

            TextField {
              id: kubeconfigField
              width: parent.width - loadButton.implicitWidth - Style.spacing.sm
              text: root.kubeconfigInput
              placeholderText: "~/.kube/config"
              onTextChanged: root.kubeconfigInput = text
              Keys.onReturnPressed: root.loadKubeconfig()
            }

            Button {
              id: loadButton
              text: "Connect"
              onClicked: root.loadKubeconfig()
            }
          }

          Column {
            width: parent.width
            visible: root.browsingKubeconfig
            spacing: Style.spacing.xs
            height: Style.space(170)

            Row {
              width: parent.width
              spacing: Style.spacing.sm

              Button { text: "Up"; fontSize: Style.font.bodySmall; onClicked: root.navigateUp() }

              Text {
                width: parent.width - Style.space(60)
                text: root.browseDir
                color: Qt.darker(root.contentForeground, 1.2)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
                elide: Text.ElideMiddle
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            Flickable {
              width: parent.width
              height: parent.height - Style.space(30)
              contentWidth: width
              contentHeight: browseColumn.implicitHeight
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              Column {
                id: browseColumn
                width: parent.width

                Repeater {
                  model: root.browseEntries
                  delegate: Rectangle {
                    required property var modelData
                    width: browseColumn.width
                    height: Style.space(26)
                    color: entryHover.hovered ? Style.hoverFillFor(root.contentForeground, Color.accent, Color.urgent) : "transparent"

                    Text {
                      anchors.left: parent.left
                      anchors.leftMargin: Style.spacing.md
                      anchors.verticalCenter: parent.verticalCenter
                      text: (modelData.isDir ? "› " : "  ") + modelData.name
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.bodySmall
                    }

                    HoverHandler { id: entryHover }
                    MouseArea {
                      anchors.fill: parent
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.navigateEntry(modelData)
                    }
                  }
                }
              }
            }
          }

          Text {
            text: "Clusters"
            color: Qt.darker(root.contentForeground, 1.2)
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }

          Flickable {
            width: parent.width
            height: parent.height - y
            contentWidth: width
            contentHeight: clusterColumn.implicitHeight
            clip: true
            boundsBehavior: Flickable.StopAtBounds

            Column {
              id: clusterColumn
              width: parent.width
              spacing: Style.spacing.xs

              Text {
                visible: !root.contextsLoading && root.contexts.length === 0
                text: "No clusters found in " + root.kubeconfigPath
                color: Qt.darker(root.contentForeground, 1.4)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Repeater {
                model: root.contexts
                delegate: Button {
                  required property var modelData
                  width: clusterColumn.width
                  leftAlign: true
                  text: modelData.name + (modelData.current ? "  (current)" : "")
                  onClicked: root.connectCluster(modelData.name)
                }
              }
            }
          }
        }

        // ================= MAIN SCREEN (namespaces + pods/deployments) =================
        Item {
          anchors.fill: parent
          visible: root.screen === "main"

          Flickable {
            id: nsScroll
            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: Style.space(30)
            contentWidth: nsRow.implicitWidth
            contentHeight: height
            clip: true
            flickableDirection: Flickable.HorizontalFlick
            boundsBehavior: Flickable.StopAtBounds

            Row {
              id: nsRow
              height: parent.height
              spacing: Style.spacing.sm

              Repeater {
                model: [{ label: "All namespaces", value: "" }].concat(root.namespaces.map(function (n) { return { label: n, value: n } }))

                delegate: Rectangle {
                  required property var modelData
                  readonly property bool isSelected: modelData.value === root.selectedNamespace
                  height: Style.space(24)
                  radius: height / 2
                  width: pillLabel.implicitWidth + Style.spacing.xxl
                  color: isSelected ? Color.accent : (pillHover.hovered ? Style.hoverFillFor(root.contentForeground, Color.accent, Color.urgent) : Style.normalFillFor(root.contentForeground, Color.accent, Color.urgent))

                  Text {
                    id: pillLabel
                    anchors.centerIn: parent
                    text: modelData.label
                    color: parent.isSelected ? Color.background : root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: parent.isSelected
                  }

                  HoverHandler { id: pillHover }
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.selectNamespace(modelData.value)
                  }
                }
              }
            }
          }

          Row {
            anchors.top: nsScroll.bottom
            anchors.topMargin: Style.spacing.sm
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            spacing: Style.spacing.md

            Column {
              id: sideMenu
              width: root.sideMenuWidth
              height: parent.height
              spacing: Style.spacing.xs

              Button {
                width: sideMenu.width
                leftAlign: true
                text: "Pods"
                selected: root.resourceType === "pods"
                onClicked: root.selectResourceType("pods")
              }
              Button {
                width: sideMenu.width
                leftAlign: true
                text: "Deployments"
                selected: root.resourceType === "deployments"
                onClicked: root.selectResourceType("deployments")
              }

              Text {
                visible: root.metricsNote !== "" && root.resourceType === "pods"
                width: sideMenu.width
                text: root.metricsNote
                wrapMode: Text.Wrap
                color: Qt.darker(root.contentForeground, 1.5)
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                topPadding: Style.spacing.md
              }
            }

            Column {
              id: listArea
              width: parent.width - sideMenu.width - Style.spacing.md
              height: parent.height
              spacing: Style.spacing.xs

              RowLayout {
                width: listArea.width
                visible: root.resourceType === "pods"
                spacing: Style.spacing.sm
                Item { Layout.preferredWidth: root.colStatusDot }
                Text { Layout.fillWidth: true; text: "NAME"; font.bold: true; font.pixelSize: Style.font.caption; color: Qt.darker(root.contentForeground, 1.2); font.family: root.contentFontFamily }
                Text { Layout.preferredWidth: root.colCpu; text: "CPU"; font.bold: true; font.pixelSize: Style.font.caption; color: Qt.darker(root.contentForeground, 1.2); font.family: root.contentFontFamily }
                Text { Layout.preferredWidth: root.colMem; text: "MEM"; font.bold: true; font.pixelSize: Style.font.caption; color: Qt.darker(root.contentForeground, 1.2); font.family: root.contentFontFamily }
                Text { Layout.preferredWidth: root.colRestarts; text: "RESTARTS"; font.bold: true; font.pixelSize: Style.font.caption; color: Qt.darker(root.contentForeground, 1.2); font.family: root.contentFontFamily }
                Text { Layout.preferredWidth: root.colControlledBy; text: "CONTROLLED BY"; font.bold: true; font.pixelSize: Style.font.caption; color: Qt.darker(root.contentForeground, 1.2); font.family: root.contentFontFamily }
                Text { Layout.preferredWidth: root.colAge; text: "AGE"; font.bold: true; font.pixelSize: Style.font.caption; color: Qt.darker(root.contentForeground, 1.2); font.family: root.contentFontFamily }
              }

              RowLayout {
                width: listArea.width
                visible: root.resourceType === "deployments"
                spacing: Style.spacing.sm
                Text { Layout.fillWidth: true; text: "NAME"; font.bold: true; font.pixelSize: Style.font.caption; color: Qt.darker(root.contentForeground, 1.2); font.family: root.contentFontFamily }
                Text { Layout.preferredWidth: root.colReady; text: "READY"; font.bold: true; font.pixelSize: Style.font.caption; color: Qt.darker(root.contentForeground, 1.2); font.family: root.contentFontFamily }
                Text { Layout.preferredWidth: root.colUpToDate; text: "UP-TO-DATE"; font.bold: true; font.pixelSize: Style.font.caption; color: Qt.darker(root.contentForeground, 1.2); font.family: root.contentFontFamily }
                Text { Layout.preferredWidth: root.colAvailable; text: "AVAILABLE"; font.bold: true; font.pixelSize: Style.font.caption; color: Qt.darker(root.contentForeground, 1.2); font.family: root.contentFontFamily }
                Text { Layout.preferredWidth: root.colAge; text: "AGE"; font.bold: true; font.pixelSize: Style.font.caption; color: Qt.darker(root.contentForeground, 1.2); font.family: root.contentFontFamily }
              }

              Flickable {
                width: listArea.width
                height: listArea.height - Style.space(20)
                contentWidth: width
                contentHeight: listColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Column {
                  id: listColumn
                  width: parent.width

                  Text {
                    visible: !root.listLoading && root.resourceType === "pods" && root.pods.length === 0
                    text: "No pods" + (root.selectedNamespace !== "" ? " in " + root.selectedNamespace : "")
                    color: Qt.darker(root.contentForeground, 1.4)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    topPadding: Style.spacing.lg
                  }

                  Text {
                    visible: !root.listLoading && root.resourceType === "deployments" && root.deployments.length === 0
                    text: "No deployments" + (root.selectedNamespace !== "" ? " in " + root.selectedNamespace : "")
                    color: Qt.darker(root.contentForeground, 1.4)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.bodySmall
                    topPadding: Style.spacing.lg
                  }

                  Repeater {
                    model: root.resourceType === "pods" ? root.pods : []

                    delegate: Rectangle {
                      id: podRow
                      required property var modelData
                      width: listColumn.width
                      height: Style.space(28)
                      radius: Style.cornerRadius
                      color: podRowHover.hovered ? Style.hoverFillFor(root.contentForeground, Color.accent, Color.urgent) : "transparent"

                      RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Style.spacing.xs
                        anchors.rightMargin: Style.spacing.xs
                        spacing: Style.spacing.sm

                        Rectangle {
                          Layout.preferredWidth: root.colStatusDot
                          Layout.alignment: Qt.AlignVCenter
                          width: Style.space(8)
                          height: Style.space(8)
                          radius: Style.space(4)
                          color: root.statusColor(podRow.modelData.status)
                        }

                        Text {
                          Layout.fillWidth: true
                          text: podRow.modelData.name + (root.selectedNamespace === "" ? "  · " + podRow.modelData.namespace : "")
                          color: root.contentForeground
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.body
                          elide: Text.ElideMiddle
                        }
                        Text {
                          Layout.preferredWidth: root.colCpu
                          text: podRow.modelData.cpu
                          color: Qt.darker(root.contentForeground, 1.2)
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.bodySmall
                        }
                        Text {
                          Layout.preferredWidth: root.colMem
                          text: podRow.modelData.mem
                          color: Qt.darker(root.contentForeground, 1.2)
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.bodySmall
                        }
                        Text {
                          Layout.preferredWidth: root.colRestarts
                          text: String(podRow.modelData.restarts)
                          color: podRow.modelData.restarts > 0 ? Color.urgent : Qt.darker(root.contentForeground, 1.2)
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.bodySmall
                        }
                        Text {
                          Layout.preferredWidth: root.colControlledBy
                          text: podRow.modelData.controlledBy
                          color: Qt.darker(root.contentForeground, 1.2)
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.bodySmall
                          elide: Text.ElideRight
                        }
                        Text {
                          Layout.preferredWidth: root.colAge
                          text: podRow.modelData.age
                          color: Qt.darker(root.contentForeground, 1.2)
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.bodySmall
                        }
                      }

                      HoverHandler { id: podRowHover }
                      MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.openDetail(podRow.modelData)
                      }
                    }
                  }

                  Repeater {
                    model: root.resourceType === "deployments" ? root.deployments : []

                    delegate: Rectangle {
                      id: depRow
                      required property var modelData
                      width: listColumn.width
                      height: Style.space(28)
                      radius: Style.cornerRadius
                      color: depRowHover.hovered ? Style.hoverFillFor(root.contentForeground, Color.accent, Color.urgent) : "transparent"

                      RowLayout {
                        anchors.fill: parent
                        anchors.leftMargin: Style.spacing.xs
                        anchors.rightMargin: Style.spacing.xs
                        spacing: Style.spacing.sm

                        Text {
                          Layout.fillWidth: true
                          text: depRow.modelData.name + (root.selectedNamespace === "" ? "  · " + depRow.modelData.namespace : "")
                          color: root.contentForeground
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.body
                          elide: Text.ElideMiddle
                        }
                        Text {
                          Layout.preferredWidth: root.colReady
                          text: depRow.modelData.ready
                          color: Qt.darker(root.contentForeground, 1.2)
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.bodySmall
                        }
                        Text {
                          Layout.preferredWidth: root.colUpToDate
                          text: String(depRow.modelData.upToDate)
                          color: Qt.darker(root.contentForeground, 1.2)
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.bodySmall
                        }
                        Text {
                          Layout.preferredWidth: root.colAvailable
                          text: String(depRow.modelData.available)
                          color: Qt.darker(root.contentForeground, 1.2)
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.bodySmall
                        }
                        Text {
                          Layout.preferredWidth: root.colAge
                          text: depRow.modelData.age
                          color: Qt.darker(root.contentForeground, 1.2)
                          font.family: root.contentFontFamily
                          font.pixelSize: Style.font.bodySmall
                        }
                      }

                      HoverHandler { id: depRowHover }
                    }
                  }
                }
              }
            }
          }
        }

        // ================= DETAIL SCREEN =================
        // One glance instead of tabs: env + metrics side by side on top,
        // logs spanning the full width underneath.
        Item {
          id: detailScreen
          anchors.fill: parent
          visible: root.screen === "detail"

          readonly property real gap: Style.spacing.md
          readonly property real paneWidth: (width - gap) / 2
          readonly property real paneHeight: (height - gap) / 2
          // visible:false does not stop a binding from evaluating, so the
          // "last sample" reads below have to go through this guarded
          // lookup rather than indexing metricsHistory directly.
          readonly property var latestMetric: root.metricsHistory.length > 0 ? root.metricsHistory[root.metricsHistory.length - 1] : null

          // ---- ENV (top-left) ----
          Rectangle {
            id: envPane
            x: 0
            y: 0
            width: detailScreen.paneWidth
            height: detailScreen.paneHeight
            radius: Style.cornerRadius
            color: Style.normalFillFor(root.contentForeground, Color.accent, Color.urgent)

            Item {
              anchors.fill: parent
              anchors.margins: Style.spacing.sm

              Column {
                id: envHeader
                anchors.top: parent.top
                width: parent.width
                spacing: Style.spacing.xxs

                Text {
                  text: "ENV"
                  color: Qt.darker(root.contentForeground, 1.2)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                Text {
                  visible: root.envError !== ""
                  width: parent.width
                  text: root.envError
                  color: Color.urgent
                  wrapMode: Text.Wrap
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Flickable {
                anchors.top: envHeader.bottom
                anchors.topMargin: Style.spacing.xs
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                contentWidth: width
                contentHeight: envColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Column {
                  id: envColumn
                  width: parent.width

                  Text {
                    visible: !root.envLoading && root.envList.length === 0 && root.envError === ""
                    text: root.envLoading ? "Loading…" : "No environment variables"
                    color: Qt.darker(root.contentForeground, 1.4)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Repeater {
                    model: root.envList
                    delegate: Column {
                      required property var modelData
                      width: envColumn.width
                      bottomPadding: Style.spacing.xs

                      Text {
                        width: parent.width
                        text: modelData.key
                        color: Color.accent
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                        font.bold: true
                        elide: Text.ElideRight
                      }
                      Text {
                        width: parent.width
                        text: modelData.value
                        color: root.contentForeground
                        font.family: root.contentFontFamily
                        font.pixelSize: Style.font.caption
                        wrapMode: Text.Wrap
                      }
                    }
                  }
                }
              }
            }
          }

          // ---- METRICS (top-right) ----
          Rectangle {
            id: metricsPane
            x: detailScreen.paneWidth + detailScreen.gap
            y: 0
            width: detailScreen.paneWidth
            height: detailScreen.paneHeight
            radius: Style.cornerRadius
            color: Style.normalFillFor(root.contentForeground, Color.accent, Color.urgent)

            Item {
              anchors.fill: parent
              anchors.margins: Style.spacing.sm

              Column {
                id: metricsFixed
                anchors.top: parent.top
                width: parent.width
                spacing: Style.spacing.xxs

                Text {
                  text: "METRICS"
                  color: Qt.darker(root.contentForeground, 1.2)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
                Text {
                  visible: root.metricsError !== ""
                  width: parent.width
                  text: root.metricsError
                  color: Color.urgent
                  wrapMode: Text.Wrap
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
                Text {
                  visible: root.metricsError === "" && !root.metricsLoading && root.metricsHistory.length === 0
                  text: root.metricsLoading ? "Loading…" : "No metrics"
                  color: Qt.darker(root.contentForeground, 1.4)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }

                Row {
                  visible: root.metricsHistory.length > 0
                  width: parent.width
                  spacing: Style.spacing.sm

                  Text {
                    width: Style.space(66)
                    text: detailScreen.latestMetric ? ("CPU " + Math.round(detailScreen.latestMetric.cpu) + "m") : ""
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Canvas {
                    id: cpuChart
                    width: parent.width - Style.space(72)
                    height: Style.space(26)
                    property var series: root.metricsHistory.map(function (s) { return s.cpu })
                    onSeriesChanged: requestPaint()
                    onPaint: {
                      var ctx = getContext("2d")
                      ctx.reset()
                      if (series.length < 2) return
                      var maxV = Math.max.apply(null, series.concat([1]))
                      ctx.strokeStyle = Color.accent
                      ctx.lineWidth = 1.5
                      ctx.beginPath()
                      for (var i = 0; i < series.length; i++) {
                        var px = (i / (series.length - 1)) * width
                        var py = height - (series[i] / maxV) * (height - 2) - 1
                        if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py)
                      }
                      ctx.stroke()
                    }
                  }
                }

                Row {
                  visible: root.metricsHistory.length > 0
                  width: parent.width
                  spacing: Style.spacing.sm

                  Text {
                    width: Style.space(66)
                    text: detailScreen.latestMetric ? ("MEM " + Math.round(detailScreen.latestMetric.mem) + "Mi") : ""
                    color: root.contentForeground
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Canvas {
                    id: memChart
                    width: parent.width - Style.space(72)
                    height: Style.space(26)
                    property var series: root.metricsHistory.map(function (s) { return s.mem })
                    onSeriesChanged: requestPaint()
                    onPaint: {
                      var ctx = getContext("2d")
                      ctx.reset()
                      if (series.length < 2) return
                      var maxV = Math.max.apply(null, series.concat([1]))
                      ctx.strokeStyle = Color.urgent
                      ctx.lineWidth = 1.5
                      ctx.beginPath()
                      for (var i = 0; i < series.length; i++) {
                        var px = (i / (series.length - 1)) * width
                        var py = height - (series[i] / maxV) * (height - 2) - 1
                        if (i === 0) ctx.moveTo(px, py); else ctx.lineTo(px, py)
                      }
                      ctx.stroke()
                    }
                  }
                }
              }

              Flickable {
                anchors.top: metricsFixed.bottom
                anchors.topMargin: Style.spacing.xs
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                visible: root.metricsContainers.length > 1
                contentWidth: width
                contentHeight: containerColumn.implicitHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                Column {
                  id: containerColumn
                  width: parent.width

                  RowLayout {
                    width: containerColumn.width
                    Text { Layout.fillWidth: true; text: "CONTAINER"; font.bold: true; font.pixelSize: Style.font.caption; color: Qt.darker(root.contentForeground, 1.2); font.family: root.contentFontFamily }
                    Text { Layout.preferredWidth: root.colCpu; text: "CPU"; font.bold: true; font.pixelSize: Style.font.caption; color: Qt.darker(root.contentForeground, 1.2); font.family: root.contentFontFamily }
                    Text { Layout.preferredWidth: root.colMem; text: "MEM"; font.bold: true; font.pixelSize: Style.font.caption; color: Qt.darker(root.contentForeground, 1.2); font.family: root.contentFontFamily }
                  }

                  Repeater {
                    model: root.metricsContainers
                    delegate: RowLayout {
                      required property var modelData
                      width: containerColumn.width
                      Text { Layout.fillWidth: true; text: modelData.name; color: root.contentForeground; font.family: root.contentFontFamily; font.pixelSize: Style.font.caption; elide: Text.ElideRight }
                      Text { Layout.preferredWidth: root.colCpu; text: modelData.cpu; color: Qt.darker(root.contentForeground, 1.2); font.family: root.contentFontFamily; font.pixelSize: Style.font.caption }
                      Text { Layout.preferredWidth: root.colMem; text: modelData.mem; color: Qt.darker(root.contentForeground, 1.2); font.family: root.contentFontFamily; font.pixelSize: Style.font.caption }
                    }
                  }
                }
              }
            }
          }

          // ---- LOGS (bottom, full width) ----
          Rectangle {
            id: logsPane
            x: 0
            y: detailScreen.paneHeight + detailScreen.gap
            width: detailScreen.width
            height: detailScreen.paneHeight
            radius: Style.cornerRadius
            color: Style.normalFillFor(root.contentForeground, Color.accent, Color.urgent)

            Item {
              anchors.fill: parent
              anchors.margins: Style.spacing.sm

              Column {
                id: logsHeader
                anchors.top: parent.top
                width: parent.width
                spacing: Style.spacing.xxs

                Row {
                  width: parent.width
                  spacing: Style.spacing.sm

                  Text {
                    text: "LOGS"
                    color: Qt.darker(root.contentForeground, 1.2)
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    font.bold: true
                  }

                  Text {
                    text: "● Jump to latest"
                    visible: !root.autoScrollLogs
                    color: Color.accent
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption

                    MouseArea {
                      anchors.fill: parent
                      anchors.margins: -Style.spacing.xs
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        root.autoScrollLogs = true
                        logsScroll.scrollToEnd()
                      }
                    }
                  }
                }
                Text {
                  visible: root.logsError !== ""
                  width: parent.width
                  text: root.logsError
                  color: Color.urgent
                  wrapMode: Text.Wrap
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Flickable {
                id: logsScroll
                anchors.top: logsHeader.bottom
                anchors.topMargin: Style.spacing.xs
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                contentWidth: width
                contentHeight: logsField.paintedHeight
                clip: true
                boundsBehavior: Flickable.StopAtBounds

                function scrollToEnd() {
                  logsScroll.contentY = Math.max(0, logsScroll.contentHeight - logsScroll.height)
                }

                // New text (a refresh) grows contentHeight; a resized popup
                // changes the viewport itself — either should keep pinning
                // to the end while the user hasn't scrolled away from it.
                onContentHeightChanged: if (root.autoScrollLogs) Qt.callLater(scrollToEnd)
                onHeightChanged: if (root.autoScrollLogs) Qt.callLater(scrollToEnd)
                // moving/movementEnded only fire for interactive drag/flick/
                // wheel scrolling, not the direct contentY assignment in
                // scrollToEnd() above, so this only reacts to the user.
                onMovementEnded: root.autoScrollLogs = atYEnd

                TextEdit {
                  id: logsField
                  width: parent.width
                  text: root.logsText !== "" ? root.logsText : (root.logsLoading ? "Loading…" : "No log output")
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.bodySmall
                  wrapMode: TextEdit.Wrap
                  readOnly: true
                  selectByMouse: true
                }
              }
            }
          }
        }
      }
    }
  }
}
