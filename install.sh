#!/bin/bash
echo "GLKVM cloud is building..."

# ========= Config you can tweak =========
OWNER="CU-Jon"
REPO="glkvm-cloud"
# Filter releases by tag prefix so this branch has its own 'latest'
TAG_PREFIX="${TAG_PREFIX:-glkvm-cloud-ldap}"

# Asset names produced by build.sh (do not change unless build.sh changes)
ASSET_APP="glkvm-cloud-ldap.tar"
ASSET_TURN="glkvm-coturn.tar"
ASSET_COMPOSE="docker-compose.tar.gz"
# =======================================

PLATFORM="unknown"

# Detect operating system
if [ -f /etc/os-release ]; then
  . /etc/os-release
  OS_ID=$ID
  OS_ID_LIKE=${ID_LIKE:-}
  PRETTY_NAME=${PRETTY_NAME:-$ID}
else
  echo "Cannot determine OS. Exiting."
  exit 1
fi

# Install base deps (Docker, compose plugin/legacy, curl, firewall, jq)
if [[ "$OS_ID" == "debian" || "$OS_ID" == "ubuntu" || "$OS_ID_LIKE" == *"debian"* ]]; then
  export DEBIAN_FRONTEND=noninteractive
  if [ -f /etc/needrestart/needrestart.conf ]; then
    sed -i -e "s/^\s*#\?\s*\$nrconf{restart}.*/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf || true
  fi

  PLATFORM="debian"
  echo "Detected Debian-based system: $PRETTY_NAME"
  apt-get update
  apt-get install -y docker.io docker-compose curl ufw jq

  # Firewall rules
  ufw allow 443/tcp
  ufw allow 10443/tcp
  ufw allow 5912/tcp
  ufw allow 3478/tcp
  ufw allow 3478/udp
  echo "Firewall rules updated via UFW."

elif [[ "$OS_ID" == "centos" || "$OS_ID" == "rhel" || "$OS_ID" == "almalinux" || "$OS_ID" == "rocky" || "$OS_ID_LIKE" == *"rhel"* ]]; then
  PLATFORM="redhat"
  echo "Detected Red Hat-based system: $PRETTY_NAME"
  dnf makecache
  dnf install -y curl dnf-plugins-core jq
  dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  dnf install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  systemctl enable --now docker

  # firewalld rules
  firewall-cmd --permanent --add-port=443/tcp
  firewall-cmd --permanent --add-port=10443/tcp
  firewall-cmd --permanent --add-port=5912/tcp
  firewall-cmd --permanent --add-port=3478/tcp
  firewall-cmd --permanent --add-port=3478/udp
  firewall-cmd --reload
  echo "Firewall rules updated via firewalld."

else
  echo "Unsupported OS: $PRETTY_NAME"
  exit 1
fi

echo "Platform detected: $PLATFORM"

GLKVM_DIR="$PWD/glkvm_cloud"
mkdir -p "$GLKVM_DIR"
echo "Using directory: $GLKVM_DIR"

# -------- helper: get latest matching release (by TAG_PREFIX) --------
api() {
  # For private repos: add a token and uncomment Authorization header
  # curl -fsSL -H "Accept: application/vnd.github+json" -H "Authorization: Bearer $GITHUB_TOKEN" \
  curl -fsSL -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${OWNER}/${REPO}/releases?per_page=50"
}

echo "Querying GitHub Releases for ${OWNER}/${REPO} (prefix: ${TAG_PREFIX})..."
release_json="$(api)"

if [ -z "$release_json" ]; then
  echo "❌ Failed to fetch releases from GitHub API."
  exit 1
fi

# Pick the newest release whose tag_name starts with TAG_PREFIX
release_block="$(echo "$release_json" | jq -r --arg pfx "${TAG_PREFIX}-" '
  .[] | select(.tag_name | startswith($pfx)) | . | @base64
' | head -n1)"

if [ -z "$release_block" ]; then
  echo "❌ No release found with tag prefix '${TAG_PREFIX}-'."
  echo "   Make sure your Actions workflow created a release with a tag like '${TAG_PREFIX}-<something>'."
  exit 1
fi

decode64() { echo "$1" | base64 -d; }
rel="$(decode64 "$release_block")"

REL_TAG="$(echo "$rel" | jq -r '.tag_name')"
echo "Found release: $REL_TAG"

get_asset_url() {
  local name="$1"
  echo "$rel" | jq -r --arg name "$name" '
    .assets[] | select(.name == $name) | .browser_download_url
  '
}

APP_URL="$(get_asset_url "$ASSET_APP")"
TURN_URL="$(get_asset_url "$ASSET_TURN")"
COMPOSE_URL="$(get_asset_url "$ASSET_COMPOSE")"

if [[ -z "$APP_URL" || -z "$TURN_URL" || -z "$COMPOSE_URL" ]]; then
  echo "❌ One or more expected assets were not found in release $REL_TAG:"
  echo "   - $ASSET_APP"
  echo "   - $ASSET_TURN"
  echo "   - $ASSET_COMPOSE"
  exit 1
fi

IMAGE_PATH_APP="$GLKVM_DIR/$ASSET_APP"
IMAGE_PATH_TURN="$GLKVM_DIR/$ASSET_TURN"
COMPOSE_PATH="$GLKVM_DIR/$ASSET_COMPOSE"

echo "Downloading release assets..."
curl -L -o "$IMAGE_PATH_APP" "$APP_URL"
curl -L -o "$IMAGE_PATH_TURN" "$TURN_URL"
curl -L -o "$COMPOSE_PATH" "$COMPOSE_URL"
echo "✅ Downloads complete."

echo "Importing Docker images..."
docker load -i "$IMAGE_PATH_APP"
docker load -i "$IMAGE_PATH_TURN"
echo "✅ Docker images imported."

echo "Extracting docker-compose package..."
tar -xzf "$COMPOSE_PATH" -C "$GLKVM_DIR"
echo "✅ docker-compose extracted."

cd "$GLKVM_DIR"

# Prepare .env file
ENV_EXISTED=false
if [ -f ".env" ]; then
  ENV_EXISTED=true
  BACKUP_DATE=$(date +"%Y%m%d_%H%M%S")
  cp .env ".env_${BACKUP_DATE}.backup"
  echo "⚠️  .env already exists; created backup as .env_${BACKUP_DATE}.backup"
else
  cp .env.example .env
  echo "✅ Created .env from .env.example"
fi

# Update GLKVM_IMAGE in .env file
sed -i "s|^GLKVM_IMAGE=.*|GLKVM_IMAGE=glkvm-cloud-ldap:latest|" .env
echo "✅ Updated GLKVM_IMAGE to use LDAP image."

# Public IP helper
get_public_ip() {
  ip=$(curl -s --max-time 5 https://api.ipify.org) && [ -n "$ip" ] && echo "$ip" && return 0
  ip=$(curl -s --max-time 5 https://ifconfig.me)   && [ -n "$ip" ] && echo "$ip" && return 0
  return 1
}

PUBLIC_IP=$(get_public_ip)
if [[ -z "$PUBLIC_IP" ]]; then
  echo "❌ Failed to get public IP."
  exit 1
fi
echo "Detected public IP: $PUBLIC_IP"

generate_random_string() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32; }

# Only update credentials if .env was newly created (not if it existed before)
if [ "$ENV_EXISTED" = false ]; then
  echo "Generating new credentials for fresh .env file..."
  TOKEN=$(generate_random_string)
  PASSWORD=$(generate_random_string)
  WEBRTC_USERNAME=$(generate_random_string)
  WEBRTC_PASSWORD=$(generate_random_string)

  # Update .env with generated values
  sed -i "s|^RTTYS_TOKEN=.*|RTTYS_TOKEN=$TOKEN|" .env
  sed -i "s|^RTTYS_PASS=.*|RTTYS_PASS=$PASSWORD|" .env
  sed -i "s|^TURN_USER=.*|TURN_USER=$WEBRTC_USERNAME|" .env
  sed -i "s|^TURN_PASS=.*|TURN_PASS=$WEBRTC_PASSWORD|" .env
  sed -i "s|^GLKVM_ACCESS_IP=.*|GLKVM_ACCESS_IP=$PUBLIC_IP|" .env
  echo "✅ Updated .env with generated credentials."
else
  echo "✅ Existing .env found - preserved existing credentials, only updated GLKVM_IMAGE."
  # Extract existing values from .env for display purposes
  PUBLIC_IP=$(grep "^GLKVM_ACCESS_IP=" .env | cut -d'=' -f2)
  PASSWORD=$(grep "^RTTYS_PASS=" .env | cut -d'=' -f2)
fi

# Compose up (OS-specific)
if [ "$PLATFORM" = "debian" ]; then
  docker-compose up -d
else
  docker compose up -d
fi

echo ""
echo "✅ GLKVM Cloud has been successfully initialized at:"
echo "   $GLKVM_DIR"
echo ""
echo "Open ports:"
echo "  - 443/TCP (Web UI)"
echo "  - 10443/TCP (Device Web remote access)"
echo "  - 5912/TCP (Device connection)"
echo "  - 3478/TCP/UDP (TURN)"
echo ""
echo "🌐 Access via: https://$PUBLIC_IP"
echo "   ⚠️ Using an IP will warn about TLS unless you add your own domain/cert."
echo ""
echo "🔑 Web UI password: $PASSWORD"
echo ""
