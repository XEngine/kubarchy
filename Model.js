.pragma library

// Pure parsing/formatting helpers for the Kubernetes plugin. Kept out of
// Panel.qml so the kubectl-output parsing can be reasoned about (and, during
// development, unit-tested with plain node) independently of the UI.

function formatAge(creationTimestamp, now) {
  now = now || new Date()
  var created = new Date(creationTimestamp)
  var seconds = Math.max(0, Math.floor((now - created) / 1000))
  if (seconds < 60) return seconds + "s"
  var minutes = Math.floor(seconds / 60)
  if (minutes < 60) return minutes + "m"
  var hours = Math.floor(minutes / 60)
  if (hours < 24) return hours + "h" + (minutes % 60 ? (minutes % 60) + "m" : "")
  var days = Math.floor(hours / 24)
  if (days < 365) return days + "d" + (hours % 24 ? (hours % 24) + "h" : "")
  var years = Math.floor(days / 365)
  var months = Math.floor((days % 365) / 30)
  return years + "y" + (months ? months + "mo" : "")
}

function controlledBy(ownerReferences) {
  if (!ownerReferences || ownerReferences.length === 0) return ""
  var o = ownerReferences[0]
  return (o.kind || "") + "/" + (o.name || "")
}

function podRestarts(containerStatuses) {
  if (!containerStatuses) return 0
  var total = 0
  for (var i = 0; i < containerStatuses.length; i++) total += (containerStatuses[i].restartCount || 0)
  return total
}

function containerNames(spec) {
  var names = []
  if (spec && spec.containers) for (var i = 0; i < spec.containers.length; i++) names.push(spec.containers[i].name)
  return names
}

function parsePodsJson(rawText) {
  var data
  try { data = JSON.parse(rawText) } catch (e) { return [] }
  var items = (data && data.items) || []
  var result = []
  for (var i = 0; i < items.length; i++) {
    var it = items[i]
    result.push({
      name: it.metadata.name,
      namespace: it.metadata.namespace,
      status: (it.status && it.status.phase) || "Unknown",
      restarts: podRestarts(it.status && it.status.containerStatuses),
      controlledBy: controlledBy(it.metadata.ownerReferences),
      age: formatAge(it.metadata.creationTimestamp),
      containers: containerNames(it.spec),
      cpu: "-",
      mem: "-"
    })
  }
  return result
}

function parseDeploymentsJson(rawText) {
  var data
  try { data = JSON.parse(rawText) } catch (e) { return [] }
  var items = (data && data.items) || []
  var result = []
  for (var i = 0; i < items.length; i++) {
    var it = items[i]
    var st = it.status || {}
    result.push({
      name: it.metadata.name,
      namespace: it.metadata.namespace,
      ready: (st.readyReplicas || 0) + "/" + (st.replicas || 0),
      upToDate: st.updatedReplicas || 0,
      available: st.availableReplicas || 0,
      age: formatAge(it.metadata.creationTimestamp)
    })
  }
  return result
}

// `kubectl top pods` (single namespace) header is "NAME CPU(cores) MEMORY(bytes)";
// `kubectl top pods -A` (all namespaces) header is "NAMESPACE NAME CPU(cores) MEMORY(bytes)".
function parseTopText(rawText, allNamespaces) {
  var lines = String(rawText || "").split("\n").map(function (l) { return l.trim() }).filter(function (l) { return l.length > 0 })
  var map = {}
  for (var i = 0; i < lines.length; i++) {
    if (/^NAME(SPACE)?\s/i.test(lines[i])) continue
    var parts = lines[i].split(/\s+/)
    if (allNamespaces && parts.length >= 4) map[parts[0] + "/" + parts[1]] = { cpu: parts[2], mem: parts[3] }
    else if (!allNamespaces && parts.length >= 3) map[parts[0]] = { cpu: parts[1], mem: parts[2] }
  }
  return map
}

// `kubectl top pod <name> --containers` output:
// POD      NAME      CPU(cores)   MEMORY(bytes)
// mypod    app       12m          45Mi
// mypod    sidecar   3m           10Mi
function parseTopContainers(rawText) {
  var lines = String(rawText || "").split("\n").map(function (l) { return l.trim() }).filter(function (l) { return l.length > 0 })
  var result = []
  for (var i = 0; i < lines.length; i++) {
    if (/^POD\s/i.test(lines[i])) continue
    var parts = lines[i].split(/\s+/)
    if (parts.length >= 4) result.push({ name: parts[1], cpu: parts[2], mem: parts[3] })
  }
  return result
}

// "12m" -> 12, "2" (whole cores) -> 2000. null when unknown/blank ("-").
function parseCpuMillis(s) {
  s = String(s || "").trim()
  if (s === "" || s === "-") return null
  if (s.charAt(s.length - 1) === "m") { var v = parseFloat(s); return isNaN(v) ? null : v }
  var n = parseFloat(s)
  return isNaN(n) ? null : n * 1000
}

// "322Mi" -> 322, "1Gi" -> 1024, "512Ki" -> 0.5, all normalized to Mi.
function parseMemMi(s) {
  s = String(s || "").trim()
  if (s === "" || s === "-") return null
  var m = s.match(/^([0-9.]+)([A-Za-z]*)$/)
  if (!m) return null
  var n = parseFloat(m[1])
  if (isNaN(n)) return null
  switch (m[2].toLowerCase()) {
    case "ki": return n / 1024
    case "mi": return n
    case "gi": return n * 1024
    case "ti": return n * 1024 * 1024
    case "": return n / (1024 * 1024)
    default: return n
  }
}

function sumContainerCpu(containers) {
  var total = 0, any = false
  for (var i = 0; i < containers.length; i++) {
    var v = parseCpuMillis(containers[i].cpu)
    if (v !== null) { total += v; any = true }
  }
  return any ? total : null
}

function sumContainerMem(containers) {
  var total = 0, any = false
  for (var i = 0; i < containers.length; i++) {
    var v = parseMemMi(containers[i].mem)
    if (v !== null) { total += v; any = true }
  }
  return any ? total : null
}

function mergeTop(pods, topMap, allNamespaces) {
  for (var i = 0; i < pods.length; i++) {
    var key = allNamespaces ? (pods[i].namespace + "/" + pods[i].name) : pods[i].name
    var m = topMap[key]
    if (m) { pods[i].cpu = m.cpu; pods[i].mem = m.mem }
  }
  return pods
}

function parseContexts(rawText, currentContext) {
  var lines = String(rawText || "").split("\n").map(function (l) { return l.trim() }).filter(function (l) { return l.length > 0 })
  return lines.map(function (name) { return { name: name, current: name === currentContext } })
}

function parseNamespaces(rawText) {
  return String(rawText || "").split("\n").map(function (l) { return l.trim() }).filter(function (l) { return l.length > 0 })
}

// `kubectl exec ... -- env` output, one VAR=value per line.
function parseEnvText(rawText) {
  var lines = String(rawText || "").split("\n")
  var result = []
  for (var i = 0; i < lines.length; i++) {
    var line = lines[i]
    if (line.trim() === "") continue
    var idx = line.indexOf("=")
    if (idx < 0) { result.push({ key: line, value: "" }); continue }
    result.push({ key: line.substring(0, idx), value: line.substring(idx + 1) })
  }
  result.sort(function (a, b) { return a.key < b.key ? -1 : (a.key > b.key ? 1 : 0) })
  return result
}

// `ls -1ap` output: directories are suffixed with "/". Used by the kubeconfig
// file browser; "." is dropped since ".." already covers "go up".
function parseDirListing(rawText) {
  var lines = String(rawText || "").split("\n").map(function (l) { return l.trim() }).filter(function (l) { return l.length > 0 && l !== "./" })
  var dirs = []
  var files = []
  for (var i = 0; i < lines.length; i++) {
    var isDir = lines[i].charAt(lines[i].length - 1) === "/"
    var name = isDir ? lines[i].slice(0, -1) : lines[i]
    if (isDir) dirs.push(name)
    else files.push(name)
  }
  dirs.sort()
  files.sort()
  return dirs.concat(files).map(function (name, idx) { return { name: name, isDir: idx < dirs.length } })
}

// Single-quoted for safe interpolation into a `bash -c` string.
function shq(s) {
  return "'" + String(s).replace(/'/g, "'\\''") + "'"
}

function expandHome(p, home) {
  if (!p) return p
  if (p === "~") return home
  if (p.indexOf("~/") === 0) return home + p.substring(1)
  return p
}

function joinPath(dir, name) {
  if (dir === "/") return "/" + name
  return dir + "/" + name
}

function parentPath(dir) {
  if (dir === "/" || dir === "") return "/"
  var idx = dir.lastIndexOf("/")
  if (idx <= 0) return "/"
  return dir.substring(0, idx)
}
