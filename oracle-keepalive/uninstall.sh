#!/usr/bin/env bash
set -euo pipefail

INSTALL_DIR="/opt/oracle-keepalive"
MODE="keep-docker"

usage() {
  cat <<'EOF'
Usage: curl -fsSL URL/uninstall.sh | sudo bash -s -- [--keep-docker|--remove-docker]

  --keep-docker    Remove this workload and its files; keep Docker (default)
  --remove-docker  Also uninstall Docker packages, if no other containers exist
EOF
}

if [[ $(id -u) -ne 0 ]]; then
  echo "Run with sudo" >&2
  exit 1
fi

while (($#)); do
  case "$1" in
    --keep-docker) MODE="keep-docker" ;;
    --remove-docker) MODE="remove-docker" ;;
    --help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

if [[ -L "$INSTALL_DIR" ]]; then
  echo "$INSTALL_DIR is a symlink; refusing to remove it" >&2
  exit 1
fi

if [[ "$MODE" == "remove-docker" ]]; then
  if ! command -v docker >/dev/null || ! docker info >/dev/null 2>&1; then
    echo "Docker must be running to check for other containers before removal" >&2
    exit 1
  fi
  own_id="$(docker inspect --format '{{.Id}}' keeporaclealive 2>/dev/null || true)"
  while IFS= read -r container_id; do
    if [[ -n "$container_id" && "$container_id" != "$own_id" ]]; then
      echo "Another Docker container exists ($container_id); Docker will be kept. Run with --keep-docker to remove only this workload." >&2
      exit 1
    fi
  done < <(docker ps -aq --no-trunc)
fi

if command -v docker >/dev/null && docker info >/dev/null 2>&1; then
  if [[ -f "$INSTALL_DIR/compose.yaml" ]] && docker compose version >/dev/null 2>&1; then
    docker compose -f "$INSTALL_DIR/compose.yaml" down
  elif docker inspect keeporaclealive >/dev/null 2>&1; then
    project="$(docker inspect --format '{{index .Config.Labels "com.docker.compose.project"}}' keeporaclealive 2>/dev/null || true)"
    if [[ "$project" != "oracle-keepalive" ]]; then
      echo "A container named keeporaclealive exists but is not from this project; refusing to remove it" >&2
      exit 1
    fi
    docker rm -f keeporaclealive
  fi
  image_id="$(docker image ls -q oracle-keepalive-keeporaclealive:latest | head -n 1)"
  if [[ -n "$image_id" ]]; then
    docker image rm "$image_id" >/dev/null 2>&1 || echo "Project image is still used elsewhere; kept it"
  fi
fi

if [[ -d "$INSTALL_DIR" ]]; then
  rm -r -- "$INSTALL_DIR"
fi
echo "Removed Oracle keepalive container, project image (if unused), and $INSTALL_DIR"

if [[ "$MODE" == "keep-docker" ]]; then
  echo "Docker was kept"
  exit 0
fi

packages=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras docker.io docker-compose-v2)
installed=()
if command -v apt-get >/dev/null && command -v dpkg-query >/dev/null; then
  for package in "${packages[@]}"; do
    if [[ "$(dpkg-query -W -f='${db:Status-Abbrev}' "$package" 2>/dev/null || true)" == ii* ]]; then
      installed+=("$package")
    fi
  done
  if ((${#installed[@]})); then
    apt-get purge -y "${installed[@]}"
  fi
elif command -v dnf >/dev/null && command -v rpm >/dev/null; then
  for package in "${packages[@]}"; do
    if rpm -q "$package" >/dev/null 2>&1; then
      installed+=("$package")
    fi
  done
  if ((${#installed[@]})); then
    dnf remove -y "${installed[@]}"
  fi
else
  echo "Unsupported package manager; Docker packages were not removed" >&2
  exit 1
fi
echo "Docker packages removed. Existing Docker data under /var/lib/docker and /var/lib/containerd was preserved."
