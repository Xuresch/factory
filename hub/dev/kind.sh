#!/usr/bin/env bash
# Run the hub in a local kind cluster, the way it runs in k8s, and feed it
# this machine's real factories.
#
#   hub/dev/kind.sh up       create cluster "factory-hub", build + load the image, deploy
#   hub/dev/kind.sh report   push this machine's repos once (factory/bin/report --full)
#   hub/dev/kind.sh watch    keep pushing every 5 s (Ctrl+C to stop)
#   hub/dev/kind.sh redeploy rebuild the image with a new tag and roll it out
#   hub/dev/kind.sh down     delete the cluster
#
# The hub is at http://127.0.0.1:${HUB_HOST_PORT:-8088}/. Everything uses
# kubectl --context kind-factory-hub; other clusters are not touched. The
# reporter's config lives in $STATE (not ~/.config/factory/hub.json), with a
# copy of your subscriptions.json, so your real setup stays as it is.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLUSTER=factory-hub
CTX="kind-$CLUSTER"
NS=factory
PORT="${HUB_HOST_PORT:-8088}"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/factory-hub-kind"
K() { kubectl --context "$CTX" -n "$NS" "$@"; }

token() {
  mkdir -p "$STATE"
  [[ -s "$STATE/token" ]] || openssl rand -hex 32 > "$STATE/token"
  cat "$STATE/token"
}

build() {  # build <tag>: image ghcr.io/xuresch/factory-hub:<tag> loaded into kind
  local image="ghcr.io/xuresch/factory-hub:$1"
  docker build -f "$ROOT/hub/Dockerfile" -t "$image" "$ROOT"
  kind load docker-image --name "$CLUSTER" "$image"
  echo "$image"
}

deploy() {  # deploy <image>
  # The example manifest, minus the Ingress (no controller in kind), with the
  # local image and a NodePort that kind maps to 127.0.0.1:$PORT.
  python3 - "$ROOT/hub/k8s.yaml" "$1" <<'EOF' | K apply -f -
import re, sys
docs = open(sys.argv[1]).read().split("\n---\n")
out = []
for d in docs:
    if re.search(r"^kind: Ingress", d, re.M):
        continue
    d = re.sub(r"image: \S+.*", f"image: {sys.argv[2]}\n          imagePullPolicy: IfNotPresent", d)
    if re.search(r"^kind: Service", d, re.M):
        d = d.replace("spec:\n", "spec:\n  type: NodePort\n", 1)
        d = d.replace("targetPort: http, name: http}", "targetPort: http, name: http, nodePort: 30080}")
    out.append(d)
print("\n---\n".join(out))
EOF
  K rollout status deploy/factory-hub --timeout=120s
}

reporter_config() {
  mkdir -p "$STATE/config/factory"
  local subs="${XDG_CONFIG_HOME:-$HOME/.config}/factory/subscriptions.json"
  [[ -f "$subs" ]] && cp "$subs" "$STATE/config/factory/subscriptions.json"
  printf '{"url": "http://127.0.0.1:%s", "token": "%s", "machine": "%s", "interval_seconds": 5}\n' \
    "$PORT" "$(token)" "$(hostname)" > "$STATE/config/factory/hub.json"
}

case "${1:-}" in
  up)
    if ! kind get clusters | grep -qx "$CLUSTER"; then
      kind create cluster --name "$CLUSTER" --wait 60s --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    extraPortMappings:
      - {containerPort: 30080, hostPort: $PORT, listenAddress: "127.0.0.1"}
EOF
    fi
    kubectl --context "$CTX" create namespace "$NS" --dry-run=client -o yaml | kubectl --context "$CTX" apply -f -
    K create secret generic factory-hub --from-literal=tokens="$(token)" --dry-run=client -o yaml | K apply -f -
    deploy "$(build "dev-$(git -C "$ROOT" rev-parse --short HEAD)-$(date +%s)" | tail -1)"
    reporter_config
    echo "hub: http://127.0.0.1:$PORT/   next: $0 report"
    ;;
  redeploy)
    deploy "$(build "dev-$(git -C "$ROOT" rev-parse --short HEAD)-$(date +%s)" | tail -1)"
    ;;
  report)
    reporter_config
    XDG_CONFIG_HOME="$STATE/config" "$ROOT/factory/bin/report" --full
    ;;
  watch)
    reporter_config
    XDG_CONFIG_HOME="$STATE/config" exec "$ROOT/factory/bin/report" --watch
    ;;
  down)
    kind delete cluster --name "$CLUSTER"
    ;;
  *)
    sed -n '2,15p' "$0"; exit 2 ;;
esac
