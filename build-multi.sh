#!/usr/bin/env bash
# build-k8s-images.sh
# Checks out Kubernetes at a given version as a git submodule and builds all
# component container images using the official release tooling.
# Supports multi-arch builds and pushing a combined manifest list to a registry.
#
# Usage:
#   ./build-k8s-images.sh <kubernetes-version> [options]
#
# Examples:
#   ./build-k8s-images.sh v1.30.0
#   ./build-k8s-images.sh v1.30.0 --registry my.registry.internal
#   ./build-k8s-images.sh v1.30.0 --registry my.registry.internal --arch amd64,arm64
#   ./build-k8s-images.sh v1.30.0 --registry my.registry.internal --arch amd64,arm64,arm --push
#   ./build-k8s-images.sh v1.30.0 --quick --load
#
# Options:
#   --registry <registry>     Image registry to tag/push images to (required for --push)
#   --arch <arch[,arch...]>   Comma-separated list of target architectures.
#                             Supported: amd64, arm64, arm, s390x, ppc64le
#                             Default: host architecture only
#   --quick                   Use quick-release-images (skips tests, faster)
#   --push                    Push arch-specific images and create a multi-arch
#                             manifest list in the registry (requires --registry)
#   --load                    Load built images into Docker after building
#   --output-dir <dir>        Directory for image tar archives (default: ./k8s-images)
#   --submodule-dir <dir>     Directory for the kubernetes submodule (default: ./kubernetes)
#   --skip-submodule          Skip submodule init/update (use existing checkout)
#   --golang-version <ver>    Override the Go version used to build (e.g. 1.23.4).
#                             Writes to .go-version inside the submodule and restores
#                             the original value when the script exits.
#   -h, --help                Show this help message

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()     { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()   { echo -e "${CYAN}[ARCH]${NC}  $*"; }
die()    { error "$*"; exit 1; }
header() { echo -e "\n${BOLD}━━━ $* ━━━${NC}"; }

# ── Defaults ─────────────────────────────────────────────────────────────────
K8S_VERSION=""
REGISTRY=""
ARCH_LIST=""        # comma-separated, e.g. "amd64,arm64"
QUICK=false
PUSH=false
LOAD=false
OUTPUT_DIR="./k8s-images"
SUBMODULE_DIR="./kubernetes"
SKIP_SUBMODULE=false
GOLANG_VERSION=""   # empty = use whatever is in .go-version

# Supported architectures (matches Kubernetes build system names)
SUPPORTED_ARCHES="amd64 arm64 arm s390x ppc64le"

# ── Argument parsing ──────────────────────────────────────────────────────────
usage() {
  grep '^#' "$0" | grep -v '#!/' | sed 's/^# \{0,1\}//'
  exit 0
}

if [[ $# -eq 0 ]]; then
  usage
fi

K8S_VERSION="$1"
shift

while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry)       REGISTRY="$2";       shift 2 ;;
    --arch)           ARCH_LIST="$2";      shift 2 ;;
    --quick)          QUICK=true;          shift   ;;
    --push)           PUSH=true;           shift   ;;
    --load)           LOAD=true;           shift   ;;
    --output-dir)     OUTPUT_DIR="$2";     shift 2 ;;
    --submodule-dir)  SUBMODULE_DIR="$2";  shift 2 ;;
    --skip-submodule) SKIP_SUBMODULE=true; shift   ;;
    --golang-version) GOLANG_VERSION="$2"; shift 2 ;;
    -h|--help)        usage ;;
    *) die "Unknown option: $1" ;;
  esac
done

# ── Validate version format ───────────────────────────────────────────────────
if [[ ! "$K8S_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$ ]]; then
  die "Invalid version format: '$K8S_VERSION'. Expected format: v1.30.0"
fi

# ── Resolve arch list ─────────────────────────────────────────────────────────
if [[ -z "$ARCH_LIST" ]]; then
  HOST_ARCH=$(uname -m)
  case "$HOST_ARCH" in
    x86_64)  ARCH_LIST="amd64" ;;
    aarch64) ARCH_LIST="arm64" ;;
    armv7l)  ARCH_LIST="arm"   ;;
    *) die "Unsupported host architecture: $HOST_ARCH. Set --arch explicitly." ;;
  esac
  log "Detected host architecture: ${ARCH_LIST}"
fi

# Parse comma-separated list into an array and validate each entry
IFS=',' read -ra ARCHES <<< "$ARCH_LIST"
for arch in "${ARCHES[@]}"; do
  if ! grep -qw "$arch" <<< "$SUPPORTED_ARCHES"; then
    die "Unsupported architecture: '${arch}'. Supported: ${SUPPORTED_ARCHES}"
  fi
done

MULTI_ARCH=false
if [[ ${#ARCHES[@]} -gt 1 ]]; then
  MULTI_ARCH=true
fi

# ── Push validation ───────────────────────────────────────────────────────────
if [[ "$PUSH" == true && -z "$REGISTRY" ]]; then
  die "--push requires --registry to be set"
fi

# ── Prerequisite checks ───────────────────────────────────────────────────────
header "Checking prerequisites"

check_cmd() {
  if command -v "$1" &>/dev/null; then
    ok "$1 found ($(command -v "$1"))"
  else
    die "$1 is required but not found. Please install it and retry."
  fi
}

check_cmd git
check_cmd docker
check_cmd make
check_cmd go

# Docker daemon must be running
if ! docker info &>/dev/null; then
  die "Docker daemon is not running. Start it with: sudo systemctl start docker"
fi
ok "Docker daemon is running"

# Go version check (Kubernetes requires Go 1.21+)
GO_VERSION=$(go version | awk '{print $3}' | sed 's/go//')
GO_MAJOR=$(echo "$GO_VERSION" | cut -d. -f1)
GO_MINOR=$(echo "$GO_VERSION" | cut -d. -f2)
if [[ "$GO_MAJOR" -lt 1 ]] || { [[ "$GO_MAJOR" -eq 1 ]] && [[ "$GO_MINOR" -lt 21 ]]; }; then
  die "Go 1.21+ is required. Found: go${GO_VERSION}"
fi
ok "Go ${GO_VERSION} is sufficient"

# For multi-arch pushes, remind about docker login
if [[ "$PUSH" == true ]]; then
  REGISTRY_HOST="${REGISTRY%%/*}"
  warn "Make sure you have run 'docker login ${REGISTRY_HOST}' before this script pushes images."
fi

# ── Submodule setup ───────────────────────────────────────────────────────────
header "Setting up Kubernetes source (${K8S_VERSION})"

if [[ "$SKIP_SUBMODULE" == false ]]; then
  if ! git rev-parse --git-dir &>/dev/null; then
    log "Not inside a git repo — initialising one"
    git init .
  fi

  if [[ ! -f ".gitmodules" ]] || ! grep -q "kubernetes" .gitmodules 2>/dev/null; then
    log "Adding kubernetes/kubernetes as a git submodule at '${SUBMODULE_DIR}'"
    git submodule add https://github.com/kubernetes/kubernetes.git "$SUBMODULE_DIR" || true
  else
    log "Submodule entry already exists in .gitmodules"
  fi

  log "Initialising submodule"
  git submodule init

  log "Fetching submodule (this may take a few minutes on first run)"
  git submodule update --depth 1 "$SUBMODULE_DIR"

  log "Checking out ${K8S_VERSION}"
  (
    cd "$SUBMODULE_DIR"
    git fetch --depth 1 origin "refs/tags/${K8S_VERSION}:refs/tags/${K8S_VERSION}"
    git checkout "tags/${K8S_VERSION}"
  )
  ok "Kubernetes source at ${K8S_VERSION}"
else
  log "--skip-submodule set; using existing checkout at '${SUBMODULE_DIR}'"
  [[ -d "$SUBMODULE_DIR" ]] || die "Submodule directory '${SUBMODULE_DIR}' does not exist"
fi

# ── Go version override ───────────────────────────────────────────────────────
GO_VERSION_FILE="${SUBMODULE_DIR}/.go-version"
ORIGINAL_GO_VERSION=""

restore_go_version() {
  if [[ -n "$ORIGINAL_GO_VERSION" ]]; then
    log "Restoring .go-version to ${ORIGINAL_GO_VERSION}"
    echo "$ORIGINAL_GO_VERSION" > "$GO_VERSION_FILE"
  fi
}

if [[ -n "$GOLANG_VERSION" ]]; then
  # Validate format: must look like 1.22.5 or 1.22
  if [[ ! "$GOLANG_VERSION" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]]; then
    die "Invalid --golang-version format: '${GOLANG_VERSION}'. Expected e.g. 1.23.4"
  fi

  # Read and save the current pinned version
  if [[ -f "$GO_VERSION_FILE" ]]; then
    ORIGINAL_GO_VERSION=$(cat "$GO_VERSION_FILE")
    log "Pinned Go version in source: ${ORIGINAL_GO_VERSION}"
  else
    warn ".go-version file not found at '${GO_VERSION_FILE}' — will create it"
  fi

  # Register the restore trap so .go-version is always put back,
  # even if the script exits early due to set -e or an error
  trap restore_go_version EXIT

  log "Overriding Go version: ${ORIGINAL_GO_VERSION:-"(none)"} → ${GOLANG_VERSION}"
  echo "$GOLANG_VERSION" > "$GO_VERSION_FILE"
  ok "Go version set to ${GOLANG_VERSION}"
else
  if [[ -f "$GO_VERSION_FILE" ]]; then
    log "Using pinned Go version from source: $(cat "$GO_VERSION_FILE")"
  fi
fi

# ── Prepare output directory ──────────────────────────────────────────────────
header "Preparing output directory"
mkdir -p "$OUTPUT_DIR"
ok "Output directory: $(realpath "$OUTPUT_DIR")"

# ── Helper: load a tar and return the image name Docker assigned ──────────────
load_tar_get_name() {
  local tar_path="$1"
  docker load -i "$tar_path" 2>&1 | grep "Loaded image" | sed 's/Loaded image[s]*: //'
}

# ── Helper: extract the component name from an image reference ────────────────
# "my.registry.internal/kube-apiserver:v1.30.0"  →  "kube-apiserver"
image_component() {
  basename "${1%%:*}"
}

# ── Build + collect loop ──────────────────────────────────────────────────────
# arch_images associative array: arch -> space-separated list of loaded image refs
declare -A arch_images

MAKE_TARGET="release-images"
if [[ "$QUICK" == true ]]; then
  MAKE_TARGET="quick-release-images"
  warn "Using quick-release-images (tests skipped)"
fi

for arch in "${ARCHES[@]}"; do
  header "Building images for linux/${arch}"
  step "Architecture: ${arch}  |  target: ${MAKE_TARGET}"

  BUILD_ENV=(
    "KUBE_BUILD_PLATFORMS=linux/${arch}"
  )
  if [[ -n "$REGISTRY" ]]; then
    BUILD_ENV+=("KUBE_DOCKER_REGISTRY=${REGISTRY}")
  fi

  log "This will pull the Kubernetes builder container on first run — may take a while"
  (
    cd "$SUBMODULE_DIR"
    env "${BUILD_ENV[@]}" make "$MAKE_TARGET"
  )
  ok "Build complete for ${arch}"

  # Collect tarballs
  RELEASE_IMAGE_DIR="${SUBMODULE_DIR}/_output/release-images/${arch}"
  [[ -d "$RELEASE_IMAGE_DIR" ]] \
    || die "Expected release images at '${RELEASE_IMAGE_DIR}' but directory not found"

  TARS=("$RELEASE_IMAGE_DIR"/*.tar)
  [[ ${#TARS[@]} -gt 0 ]] \
    || die "No .tar archives found in '${RELEASE_IMAGE_DIR}'"

  ARCH_OUTPUT="${OUTPUT_DIR}/${arch}"
  mkdir -p "$ARCH_OUTPUT"

  log "Copying ${#TARS[@]} archive(s) → ${ARCH_OUTPUT}"
  for tar in "${TARS[@]}"; do
    cp "$tar" "$ARCH_OUTPUT/"
  done
  ok "Archives saved to $(realpath "$ARCH_OUTPUT")"

  # Load images if we need them in Docker (for --load or --push)
  if [[ "$LOAD" == true || "$PUSH" == true ]]; then
    loaded_names=()
    for tar in "$ARCH_OUTPUT"/*.tar; do
      log "Loading $(basename "$tar")"
      raw_name=$(load_tar_get_name "$tar")

      if [[ -z "$raw_name" ]]; then
        warn "Could not determine image name from $(basename "$tar") — skipping"
        continue
      fi

      # Re-tag to the target registry if it isn't already there
      if [[ -n "$REGISTRY" && "$raw_name" != "${REGISTRY}/"* ]]; then
        component=$(image_component "$raw_name")
        tagged="${REGISTRY}/${component}:${K8S_VERSION}"
        docker tag "$raw_name" "$tagged"
        raw_name="$tagged"
      fi

      loaded_names+=("$raw_name")
      log "  → ${raw_name}"
    done

    arch_images["$arch"]="${loaded_names[*]:-}"
    ok "Loaded ${#loaded_names[@]} image(s) for ${arch}"
  fi

done   # ── end arch loop ────────────────────────────────────────────────────

# ── Push arch-specific images + create manifest lists ────────────────────────
if [[ "$PUSH" == true ]]; then
  header "Pushing images and creating manifest lists"

  FIRST_ARCH="${ARCHES[0]}"
  read -ra FIRST_IMAGES <<< "${arch_images[$FIRST_ARCH]:-}"
  [[ ${#FIRST_IMAGES[@]} -gt 0 ]] \
    || die "No images were loaded for ${FIRST_ARCH} — cannot create manifests"

  for base_image in "${FIRST_IMAGES[@]}"; do
    component=$(image_component "$base_image")
    manifest_ref="${REGISTRY}/${component}:${K8S_VERSION}"

    step "Component: ${component}"

    # Push each arch under an arch-suffixed tag
    arch_refs=()
    for arch in "${ARCHES[@]}"; do
      arch_tag="${manifest_ref}-${arch}"

      # Find this component's loaded image for this arch
      read -ra this_arch_images <<< "${arch_images[$arch]:-}"
      src_image=""
      for img in "${this_arch_images[@]}"; do
        if [[ "$(image_component "$img")" == "$component" ]]; then
          src_image="$img"
          break
        fi
      done

      if [[ -z "$src_image" ]]; then
        warn "No image found for '${component}' on ${arch} — skipping from manifest"
        continue
      fi

      log "  Tagging  ${src_image} → ${arch_tag}"
      docker tag "$src_image" "$arch_tag"
      log "  Pushing  ${arch_tag}"
      docker push "$arch_tag"

      arch_refs+=("$arch_tag")
    done

    if [[ ${#arch_refs[@]} -eq 0 ]]; then
      warn "No arch images available for '${component}' — skipping manifest"
      continue
    fi

    # Remove any stale local manifest
    docker manifest rm "$manifest_ref" 2>/dev/null || true

    log "  Creating manifest list → ${manifest_ref}"
    docker manifest create "$manifest_ref" "${arch_refs[@]}"

    # Annotate platform metadata for each arch
    for arch in "${ARCHES[@]}"; do
      arch_tag="${manifest_ref}-${arch}"
      if printf '%s\n' "${arch_refs[@]}" | grep -qx "$arch_tag"; then
        if [[ "$arch" == "arm" ]]; then
          # 32-bit ARM is linux/arm/v7 in the OCI platform spec
          docker manifest annotate "$manifest_ref" "$arch_tag" \
            --os linux --arch arm --variant v7
        else
          docker manifest annotate "$manifest_ref" "$arch_tag" \
            --os linux --arch "$arch"
        fi
      fi
    done

    log "  Pushing  ${manifest_ref}"
    docker manifest push "$manifest_ref"
    ok "✔ ${manifest_ref}"

  done   # end component loop

  ok "All manifest lists pushed"

  # ── Verify ─────────────────────────────────────────────────────────────────
  header "Verifying manifest lists"
  for base_image in "${FIRST_IMAGES[@]}"; do
    component=$(image_component "$base_image")
    manifest_ref="${REGISTRY}/${component}:${K8S_VERSION}"
    echo -e "  ${BOLD}${manifest_ref}${NC}"
    docker manifest inspect "$manifest_ref" \
      | grep -E '"architecture"|"os"|"variant"' \
      | sed 's/^/    /'
    echo ""
  done
fi

# ── Summary ───────────────────────────────────────────────────────────────────
header "Summary"
echo -e "  ${BOLD}Version:${NC}        ${K8S_VERSION}"
echo -e "  ${BOLD}Go version:${NC}     ${GOLANG_VERSION:-"(from .go-version: $(cat "$GO_VERSION_FILE" 2>/dev/null || echo unknown))"}"
echo -e "  ${BOLD}Architectures:${NC}  ${ARCH_LIST}"
echo -e "  ${BOLD}Multi-arch:${NC}     ${MULTI_ARCH}"
echo -e "  ${BOLD}Registry:${NC}       ${REGISTRY:-"(none — local only)"}"
echo -e "  ${BOLD}Output dir:${NC}     $(realpath "$OUTPUT_DIR")"
echo ""
echo -e "  ${BOLD}Archives by architecture:${NC}"
for arch in "${ARCHES[@]}"; do
  echo "    ${arch}/"
  shopt -s nullglob
  for tar in "$OUTPUT_DIR/$arch"/*.tar; do
    echo "      • $(basename "$tar" .tar)"
  done
  shopt -u nullglob
done
echo ""
ok "Done! 🎉"
echo ""

if [[ "$PUSH" == false ]]; then
  echo "  To load all images into Docker:"
  echo "    find ${OUTPUT_DIR} -name '*.tar' | xargs -I{} docker load -i {}"
  echo ""
  if [[ "$MULTI_ARCH" == true ]]; then
    echo "  To push with multi-arch manifests, re-run with --push --registry <registry>"
    echo ""
  fi
fi

echo "  To import into containerd (ctr):"
echo "    find ${OUTPUT_DIR} -name '*.tar' | xargs -I{} ctr images import {}"
echo ""
