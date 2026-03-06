#!/usr/bin/env bash
# build-kubelet-deb.sh
#
# Builds kubelet from a checked-out kubernetes/kubernetes git repository,
# then packages it as a Debian package matching upstream pkgs.k8s.io.
#
# Expects a directory named 'kubernetes' in the current working directory.
# All support files (kubelet.service, 10-kubeadm.conf) are fetched live from
# the upstream kubernetes/release GitHub repository. The dpkg-deb step runs
# inside a Docker container to ensure correct ownership.
#
# Requirements: docker (or podman), curl, git, make
#
# Usage:
#   ./build-kubelet-deb.sh [options]
#
# Options:
#   --arch            Target architecture: amd64 | arm64              (default: amd64)
#   --pkg-revision    Debian package revision suffix                  (default: 1.1)
#   --cni-version     Min kubernetes-cni version to depend on        (default: 1.4.0)
#   --release-ref     kubernetes/release ref for templates           (default: v0.17.10)
#   --build-image     Docker image used for dpkg-deb step            (default: debian:stable-slim)
#   --k8s-src-dir     Path to kubernetes source tree                 (default: ./kubernetes)
#   --output-dir      Where to write the final .deb                  (default: .)
#   --skip-build      Skip the kubelet compile step (binary must already exist in _output)
#   --help

set -euo pipefail

# ── defaults ──────────────────────────────────────────────────────────────────
ARCH="amd64"
PKG_REVISION="1.1"
CNI_MIN_VERSION="1.4.0"
RELEASE_REF="v0.17.10"
BUILD_IMAGE="debian:stable-slim"
K8S_SRC_DIR="$(pwd)/kubernetes"
OUTPUT_DIR="$(pwd)"
SKIP_BUILD=false

GITHUB_RAW="https://raw.githubusercontent.com/kubernetes/release"

# ── argument parsing ──────────────────────────────────────────────────────────
usage() {
  grep '^#' "$0" | grep -v '#!/' | sed 's/^# \?//'
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch)           ARCH="$2";           shift 2 ;;
    --pkg-revision)   PKG_REVISION="$2";   shift 2 ;;
    --cni-version)    CNI_MIN_VERSION="$2"; shift 2 ;;
    --release-ref)    RELEASE_REF="$2";    shift 2 ;;
    --build-image)    BUILD_IMAGE="$2";    shift 2 ;;
    --k8s-src-dir)    K8S_SRC_DIR="$2";    shift 2 ;;
    --output-dir)     OUTPUT_DIR="$2";     shift 2 ;;
    --skip-build)     SKIP_BUILD=true;     shift ;;
    --help|-h)        usage ;;
    *) echo "Unknown option: $1"; usage ;;
  esac
done

K8S_SRC_DIR="$(realpath "$K8S_SRC_DIR")"
[[ -d "$K8S_SRC_DIR" ]] || { echo "ERROR: kubernetes source dir not found: $K8S_SRC_DIR"; exit 1; }
[[ -f "$K8S_SRC_DIR/go.mod" ]] || { echo "ERROR: $K8S_SRC_DIR does not look like a kubernetes source tree (no go.mod)"; exit 1; }

# ── detect container runtime ──────────────────────────────────────────────────
if command -v docker &>/dev/null; then
  DOCKER="docker"
elif command -v podman &>/dev/null; then
  DOCKER="podman"
else
  echo "ERROR: neither 'docker' nor 'podman' found in PATH"
  exit 1
fi

# ── preflight checks ──────────────────────────────────────────────────────────
for cmd in curl git make; do
  command -v "$cmd" &>/dev/null || { echo "ERROR: '$cmd' not found in PATH"; exit 1; }
done

# ── derive the k8s version from the git tree ─────────────────────────────────
# kubernetes tags are like v1.32.0; strip the leading 'v' for the deb version.
VERSION="$(git -C "$K8S_SRC_DIR" describe --tags --abbrev=0 --match='v[0-9]*' 2>/dev/null \
           | sed 's/^v//')"
[[ -z "$VERSION" ]] && {
  echo "ERROR: could not determine version from git tags in $K8S_SRC_DIR"
  echo "       Make sure the repo has been fetched with tags: git fetch --tags"
  exit 1
}

DEB_VERSION="${VERSION}-${PKG_REVISION}"
PKG_NAME="kubelet_${DEB_VERSION}_${ARCH}.deb"

echo "==> Source         : $K8S_SRC_DIR"
echo "==> Version        : $VERSION  →  deb $DEB_VERSION"
echo "==> Arch           : $ARCH"
echo "==> Release ref    : $RELEASE_REF"
echo "==> Container      : $DOCKER / $BUILD_IMAGE"

# ── step 1: build kubelet ─────────────────────────────────────────────────────
# Output paths produced by the kubernetes build system:
#   Hermetic (build/run.sh): _output/dockerized/bin/linux/<arch>/kubelet
#   Direct (make all):       _output/bin/kubelet   (host arch only)
HERMETIC_BINARY="${K8S_SRC_DIR}/_output/dockerized/bin/linux/${ARCH}/kubelet"
DIRECT_BINARY="${K8S_SRC_DIR}/_output/bin/kubelet"

if [[ "$SKIP_BUILD" == "true" ]]; then
  echo "==> --skip-build set, skipping compile step"
else
  echo ""
  echo "==> Building kubelet (KUBE_BUILD_PLATFORMS=linux/${ARCH}) ..."
  echo "    This uses build/run.sh (hermetic Docker build) which may take a while"
  echo "    on first run as it pulls the kube-build image (~1.5 GB)."
  echo ""

  cd "$K8S_SRC_DIR"

  # build/run.sh is the upstream hermetic build path — it pulls the official
  # kube-build container and runs make inside it, so the Go toolchain version
  # exactly matches what upstream used for this k8s release.
  if [[ -x "${K8S_SRC_DIR}/build/run.sh" ]]; then
    KUBE_BUILD_PLATFORMS="linux/${ARCH}" \
      "${K8S_SRC_DIR}/build/run.sh" make WHAT=cmd/kubelet \
        KUBE_BUILD_PLATFORMS="linux/${ARCH}"
  else
    echo "WARNING: build/run.sh not found or not executable; falling back to direct make."
    echo "         This will use the host Go toolchain rather than the upstream one."
    make WHAT=cmd/kubelet KUBE_BUILD_PLATFORMS="linux/${ARCH}"
  fi

  cd - > /dev/null
fi

# ── locate the kubelet binary ─────────────────────────────────────────────────
if [[ -f "$HERMETIC_BINARY" ]]; then
  KUBELET_BINARY="$HERMETIC_BINARY"
  echo "==> Using hermetic build output: $KUBELET_BINARY"
elif [[ -f "$DIRECT_BINARY" ]]; then
  KUBELET_BINARY="$DIRECT_BINARY"
  echo "==> Using direct build output: $KUBELET_BINARY"
else
  # Last resort: walk _output for any kubelet binary
  KUBELET_BINARY="$(find "${K8S_SRC_DIR}/_output" -name kubelet -type f 2>/dev/null | head -1)"
  [[ -n "$KUBELET_BINARY" ]] || {
    echo "ERROR: kubelet binary not found under ${K8S_SRC_DIR}/_output"
    echo "       Run without --skip-build, or check that the build succeeded."
    exit 1
  }
  echo "==> Found binary: $KUBELET_BINARY"
fi

# Sanity-check: make sure it is a Linux ELF binary
file "$KUBELET_BINARY" | grep -q ELF || {
  echo "ERROR: $KUBELET_BINARY does not appear to be an ELF binary"
  file "$KUBELET_BINARY"
  exit 1
}

# ── step 2: fetch upstream template files ────────────────────────────────────
WORK_DIR="$(mktemp -d)"
trap 'sudo rm -rf "$WORK_DIR"' EXIT
PKG_ROOT="${WORK_DIR}/pkg"
TMPL_DIR="${WORK_DIR}/templates"
mkdir -p "$TMPL_DIR"

# Tries the current krel layout first, then the legacy kubepkg layout.
fetch_template() {
  local subpath="$1"
  local dest="$2"
  local krel_url="${GITHUB_RAW}/${RELEASE_REF}/cmd/krel/templates/latest/${subpath}"
  local kubepkg_url="${GITHUB_RAW}/${RELEASE_REF}/cmd/kubepkg/templates/latest/deb/${subpath}"

  echo "    Trying: ${krel_url}"
  if curl -fsSL --retry 3 -o "$dest" "$krel_url" 2>/dev/null; then
    echo "    OK (krel path)"
    return 0
  fi
  echo "    Not found, trying: ${kubepkg_url}"
  if curl -fsSL --retry 3 -o "$dest" "$kubepkg_url" 2>/dev/null; then
    echo "    OK (kubepkg path)"
    return 0
  fi
  echo "ERROR: could not fetch template '${subpath}'"
  echo "       Verify --release-ref '${RELEASE_REF}' exists in kubernetes/release."
  exit 1
}

echo ""
echo "==> Fetching upstream templates from kubernetes/release @ ${RELEASE_REF} ..."
fetch_template "kubelet/kubelet.service"    "${TMPL_DIR}/kubelet.service"
fetch_template "kubeadm/10-kubeadm.conf"   "${TMPL_DIR}/10-kubeadm.conf" \
  || fetch_template "kubelet/10-kubeadm.conf" "${TMPL_DIR}/10-kubeadm.conf"

grep -q 'ExecStart'       "${TMPL_DIR}/kubelet.service"   || { echo "ERROR: kubelet.service looks wrong";  exit 1; }
grep -q 'EnvironmentFile' "${TMPL_DIR}/10-kubeadm.conf"   || { echo "ERROR: 10-kubeadm.conf looks wrong"; exit 1; }

echo ""
echo "--- kubelet.service ---"
cat "${TMPL_DIR}/kubelet.service"
echo ""
echo "--- 10-kubeadm.conf ---"
cat "${TMPL_DIR}/10-kubeadm.conf"
echo ""

# ── step 3: assemble package tree ─────────────────────────────────────────────
mkdir -p \
  "${PKG_ROOT}/DEBIAN" \
  "${PKG_ROOT}/usr/bin" \
  "${PKG_ROOT}/lib/systemd/system" \
  "${PKG_ROOT}/etc/systemd/system/kubelet.service.d" \
  "${PKG_ROOT}/etc/kubernetes/manifests" \
  "${PKG_ROOT}/etc/default" \
  "${PKG_ROOT}/var/lib/kubelet"

install -m755 "$KUBELET_BINARY"                "${PKG_ROOT}/usr/bin/kubelet"
install -m644 "${TMPL_DIR}/kubelet.service"    "${PKG_ROOT}/lib/systemd/system/kubelet.service"
install -m644 "${TMPL_DIR}/10-kubeadm.conf"    "${PKG_ROOT}/etc/systemd/system/kubelet.service.d/10-kubeadm.conf"

cat > "${PKG_ROOT}/etc/default/kubelet" <<'EOF'
# KUBELET_EXTRA_ARGS=
EOF

# ── DEBIAN/control ────────────────────────────────────────────────────────────
cat > "${PKG_ROOT}/DEBIAN/control" <<EOF
Package: kubelet
Version: ${DEB_VERSION}
Architecture: ${ARCH}
Maintainer: Kubernetes Authors <dev@kubernetes.io>
Homepage: https://kubernetes.io
Vcs-Browser: https://github.com/kubernetes/kubernetes
Vcs-Git: https://github.com/kubernetes/kubernetes.git
Section: admin
Priority: optional
Depends: iptables (>= 1.4.21), kubernetes-cni (>= ${CNI_MIN_VERSION}), iproute2, socat, util-linux, mount, ebtables, ethtool, conntrack
Conflicts: kubelet
Replaces: kubelet
Provides: kubelet
Description: Kubernetes Node Agent
 The node agent of Kubernetes, the container cluster manager.
EOF

# ── DEBIAN/conffiles ──────────────────────────────────────────────────────────
cat > "${PKG_ROOT}/DEBIAN/conffiles" <<'EOF'
/etc/default/kubelet
/etc/systemd/system/kubelet.service.d/10-kubeadm.conf
EOF

# ── DEBIAN/postinst ───────────────────────────────────────────────────────────
cat > "${PKG_ROOT}/DEBIAN/postinst" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "configure" ] || [ "$1" = "abort-upgrade" ]; then
    if [ -d /run/systemd/system ]; then
        systemctl daemon-reload || true
        systemctl enable kubelet || true
    fi
fi
EOF
chmod 755 "${PKG_ROOT}/DEBIAN/postinst"

# ── DEBIAN/prerm ──────────────────────────────────────────────────────────────
cat > "${PKG_ROOT}/DEBIAN/prerm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "remove" ] || [ "$1" = "deconfigure" ]; then
    if [ -d /run/systemd/system ]; then
        systemctl stop kubelet || true
        systemctl disable kubelet || true
    fi
fi
EOF
chmod 755 "${PKG_ROOT}/DEBIAN/prerm"

# ── DEBIAN/postrm ─────────────────────────────────────────────────────────────
cat > "${PKG_ROOT}/DEBIAN/postrm" <<'EOF'
#!/bin/sh
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    if [ -d /run/systemd/system ]; then
        systemctl daemon-reload || true
    fi
fi
EOF
chmod 755 "${PKG_ROOT}/DEBIAN/postrm"

# ── step 4: build the .deb inside a container ─────────────────────────────────
echo "==> Building .deb inside container (${BUILD_IMAGE}) ..."

$DOCKER run --rm \
  --platform "linux/${ARCH}" \
  -v "${WORK_DIR}:/work" \
  "$BUILD_IMAGE" \
  /bin/sh -c "
    set -ex
    if ! command -v dpkg-deb >/dev/null 2>&1; then
      apt-get update -qq
      apt-get install -y --no-install-recommends dpkg-dev
    fi
    chown -R root:root /work/pkg
    dpkg-deb --build /work/pkg /work/${PKG_NAME}
  "

# ── copy to output dir ────────────────────────────────────────────────────────
mkdir -p "$OUTPUT_DIR"
cp "${WORK_DIR}/${PKG_NAME}" "${OUTPUT_DIR}/${PKG_NAME}"
DEST="${OUTPUT_DIR}/${PKG_NAME}"

# ── verify ────────────────────────────────────────────────────────────────────
echo ""
echo "==> Package contents:"
dpkg-deb -c "${DEST}" 2>/dev/null \
  || $DOCKER run --rm -v "${OUTPUT_DIR}:/out" "$BUILD_IMAGE" dpkg-deb -c "/out/${PKG_NAME}"

echo ""
echo "==> Package metadata:"
dpkg-deb -I "${DEST}" 2>/dev/null \
  || $DOCKER run --rm -v "${OUTPUT_DIR}:/out" "$BUILD_IMAGE" dpkg-deb -I "/out/${PKG_NAME}"

echo ""
echo "==> Done: ${DEST}"
echo ""
echo "To install (replaces upstream kubelet):"
echo "  sudo dpkg -i ${DEST}"
echo "  sudo apt-mark hold kubelet    # prevent apt from overwriting it"
