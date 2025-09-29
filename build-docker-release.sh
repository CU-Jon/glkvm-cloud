#!/bin/bash
set -e

echo "🔨 Building GLKVM Cloud with LDAP support..."

# Check if required tools are available
echo "Checking build dependencies..."
command -v go >/dev/null 2>&1 || { echo "❌ Go is required but not installed. Aborting." >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "❌ Docker is required but not installed. Aborting." >&2; exit 1; }
command -v yarn >/dev/null 2>&1 || command -v npm >/dev/null 2>&1 || { echo "❌ Yarn or npm is required but not installed. Aborting." >&2; exit 1; }

# Build the frontend first
echo "Building Vue.js frontend..."
cd ui/

# Install dependencies if node_modules doesn't exist
if [ ! -d "node_modules" ]; then
    echo "Installing frontend dependencies..."
    if command -v yarn >/dev/null 2>&1; then
        yarn install
    else
        npm install
    fi
fi

# Build frontend for production
echo "Compiling frontend assets..."
if command -v yarn >/dev/null 2>&1; then
    yarn build
else
    npm run build
fi

# Return to project root
cd ..

# Update Go dependencies and build the backend
echo "Updating Go dependencies..."
go mod tidy

echo "Building rttys binary for Alpine Linux (musl)..."
# Set environment for Alpine Linux (musl libc) compatibility
export CGO_ENABLED=0
export GOOS=linux
export GOARCH=amd64
go build -ldflags "-s -w" -o rttys .

# Show what we built
echo "Built binary info:"
file rttys 2>/dev/null || echo "file command not available on build system"
ls -la rttys

# Ensure the binary is executable
chmod +x rttys

# Double-check the binary is actually there
if [ ! -f "rttys" ]; then
    echo "❌ rttys binary not found after build!"
    exit 1
fi

if [ ! -x "rttys" ]; then
    echo "❌ rttys binary is not executable!"
    chmod +x rttys
fi

echo "✅ rttys binary verified"

# Build the Docker image
echo "Building Docker image..."
docker build -t glkvm-cloud-ldap:latest .

# Verify the binary is in the image
echo "Verifying rttys binary in Docker image..."
docker run --rm --entrypoint /bin/sh glkvm-cloud-ldap:latest -c "ls -la /usr/bin/rttys" || {
    echo "❌ rttys binary not found in Docker image!"
    echo "Debugging Docker build..."
    docker run --rm --entrypoint /bin/sh glkvm-cloud-ldap:latest -c "ls -la /usr/bin/"
    docker run --rm --entrypoint /bin/sh glkvm-cloud-ldap:latest -c "find / -name '*rttys*' 2>/dev/null || echo 'No rttys found'"
    exit 1
}

# Export the Docker image
echo "Exporting Docker image..."
docker save -o glkvm-cloud-ldap.tar glkvm-cloud-ldap:latest

# Download coturn image and export it
echo "Pulling and exporting coturn image..."
docker pull coturn/coturn:edge-alpine
docker save -o glkvm-coturn.tar coturn/coturn:edge-alpine

# Create docker-compose package
echo "Creating docker-compose package..."
cd docker-compose

# Fix line endings for shell scripts (critical for cross-platform compatibility)
echo "Fixing line endings in shell scripts..."
if command -v dos2unix >/dev/null 2>&1; then
    find . -name "*.sh" -type f -exec dos2unix {} \;
else
    # Fallback: use sed to remove carriage returns
    find . -name "*.sh" -type f -exec sed -i 's/\r$//' {} \;
fi

# Ensure scripts are executable before packaging
echo "Making shell scripts executable..."
find . -name "*.sh" -type f -exec chmod +x {} \;

# Verify permissions
echo "Verifying script permissions..."
find . -name "*.sh" -type f -exec ls -la {} \;

tar -czf ../docker-compose.tar.gz .
cd ..

echo "✅ Build complete! Generated files:"
echo "  - glkvm-cloud-ldap.tar (main application image)"
echo "  - glkvm-coturn.tar (coturn TURN server image)" 
echo "  - docker-compose.tar.gz (docker-compose configuration)"
echo ""
