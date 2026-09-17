# Kubarchy

A Kubernetes browser for the [Omarchy](https://omarchy.org/) shell bar. Pick a
kubeconfig and cluster, browse namespaces and pods/deployments, then drill
into a pod for its logs, resolved environment, and live CPU/memory metrics —
all without leaving the bar.

Everything is read-only `kubectl` underneath (whatever context/kubeconfig you
point it at) — there's no bundled client library and no cluster-mutating
commands anywhere in the plugin.

## Features

- **Kubeconfig picker** — defaults to `~/.kube/config`, with an in-popup file
  browser to point it at another file, and a path field to type/paste one.
- **Cluster picker** — lists every context in the kubeconfig; nothing
  connects until you pick one.
- **Namespace bar** — a horizontal, scrollable row of pill buttons
  (`All namespaces` + one per namespace).
- **Pods / Deployments side menu**, with a Lens-style pod list: status,
  CPU, memory, restart count, controlled-by, and age.
- **Pod detail**, all shown together rather than behind tabs:
  - **Logs** — timestamped, tailing the last 300 lines, auto-scrolling to
    the newest line (pauses if you scroll up to read history; click
    "● Jump to latest" to resume).
  - **Env** — the container's *resolved* environment (via `kubectl exec ...
    -- env`), not just what's declared in the pod spec.
  - **Metrics** — per-container CPU/memory from `kubectl top`, plus a small
    rolling sparkline built from samples taken on each refresh.

CPU/memory columns and the metrics pane degrade gracefully to `-` / a note
if `metrics-server` isn't installed on the cluster — the rest of the plugin
still works.

## Requirements

- `kubectl` on `PATH` for the user running the Omarchy shell, with a working
  kubeconfig.
- Optionally, [metrics-server](https://github.com/kubernetes-sigs/metrics-server)
  on the cluster for CPU/memory numbers and the sparkline chart.

## Install

```bash
omarchy plugin add https://github.com/XEngine/kubarchy.git --enable --yes
```

Or by hand:

```bash
git clone https://github.com/XEngine/kubarchy.git ~/.config/omarchy/plugins/xengine.kubarchy
omarchy-shell shell rescanPlugins
omarchy plugin enable xengine.kubarchy
```

## Update / remove

```bash
omarchy plugin update xengine.kubarchy
omarchy plugin remove xengine.kubarchy
```

## Notes on scope

This is a viewer, not a cluster manager: there is no delete/scale/exec-shell/
edit anywhere in the plugin, only `get`, `logs`, `top`, and a read-only
`exec ... -- env`. It runs unsandboxed inside `omarchy-shell` like any other
Omarchy plugin — review the QML before enabling it, same as you would for
any other third-party plugin.

## License

Unlicense — see [LICENSE](LICENSE). Do whatever you want with it.
