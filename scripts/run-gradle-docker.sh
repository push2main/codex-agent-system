#!/usr/bin/env bash
set -Eeuo pipefail

# Docker wrapper for Android/Gradle tasks.
# Provides JDK 17 + Android SDK + Gradle inside a container so that
# tasks which would otherwise be blocked by the "missing_environment"
# gate can execute normally.
#
# Usage:
#   ./scripts/run-gradle-docker.sh <command...>
#
# Environment variables (all optional):
#   GRADLE_DOCKER_IMAGE     – base image (default: eclipse-temurin:17-jdk-jammy)
#   GRADLE_DOCKER_CACHE     – host dir for Gradle caches (default: /tmp/codex-agent-system-gradle)
#   ANDROID_SDK_CACHE       – host dir for Android SDK cache (default: /tmp/codex-agent-system-android-sdk)
#   GRADLE_DOCKER_DISABLE   – set to "1" to bypass the container and exec natively
#   ANDROID_COMPILE_SDK     – compileSdk version to install (default: 34)
#   ANDROID_BUILD_TOOLS     – build-tools version (default: 34.0.0)

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GRADLE_DOCKER_IMAGE="${GRADLE_DOCKER_IMAGE:-eclipse-temurin:17-jdk-jammy}"
GRADLE_DOCKER_CACHE="${GRADLE_DOCKER_CACHE:-/tmp/codex-agent-system-gradle}"
ANDROID_SDK_CACHE="${ANDROID_SDK_CACHE:-/tmp/codex-agent-system-android-sdk}"
ANDROID_COMPILE_SDK="${ANDROID_COMPILE_SDK:-34}"
ANDROID_BUILD_TOOLS="${ANDROID_BUILD_TOOLS:-34.0.0}"

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <command...>" >&2
  exit 1
fi

if [ "${GRADLE_DOCKER_DISABLE:-0}" = "1" ]; then
  exec "$@"
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required to run Gradle/Android tasks in a container" >&2
  exit 1
fi

mkdir -p "$GRADLE_DOCKER_CACHE" "$ANDROID_SDK_CACHE"

# The setup script runs once inside the container on each invocation.
# Android cmdline-tools are cached on the host so subsequent runs are fast.
SETUP_SCRIPT='
set -eu
export ANDROID_HOME=/opt/android-sdk
export ANDROID_SDK_ROOT=$ANDROID_HOME
export PATH=$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools

# Restore cached SDK if available
if [ -d /android-sdk-cache/cmdline-tools ]; then
  cp -a /android-sdk-cache/* "$ANDROID_HOME/" 2>/dev/null || true
fi

# Install cmdline-tools if not cached
if [ ! -f "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" ]; then
  apt-get update -qq && apt-get install -y -qq --no-install-recommends unzip wget >/dev/null 2>&1
  mkdir -p "$ANDROID_HOME/cmdline-tools"
  wget -q "https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip" -O /tmp/cmdline.zip
  unzip -q /tmp/cmdline.zip -d "$ANDROID_HOME/cmdline-tools"
  mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest"
  rm -f /tmp/cmdline.zip
fi

# Accept licenses and install required SDK components
yes | sdkmanager --licenses >/dev/null 2>&1 || true
sdkmanager --install \
  "platforms;android-'"$ANDROID_COMPILE_SDK"'" \
  "build-tools;'"$ANDROID_BUILD_TOOLS"'" \
  "platform-tools" >/dev/null 2>&1

# Persist SDK to cache for next run
cp -a "$ANDROID_HOME"/* /android-sdk-cache/ 2>/dev/null || true

exec "$@"
'

docker run --rm \
  -e CI="${CI:-1}" \
  -e ANDROID_HOME=/opt/android-sdk \
  -e ANDROID_SDK_ROOT=/opt/android-sdk \
  -e ANDROID_COMPILE_SDK="$ANDROID_COMPILE_SDK" \
  -e ANDROID_BUILD_TOOLS="$ANDROID_BUILD_TOOLS" \
  -e GRADLE_USER_HOME=/gradle-cache \
  -v "$ROOT_DIR:/workspace" \
  -v "$GRADLE_DOCKER_CACHE:/gradle-cache" \
  -v "$ANDROID_SDK_CACHE:/android-sdk-cache" \
  -w /workspace \
  "$GRADLE_DOCKER_IMAGE" \
  bash -c "$SETUP_SCRIPT" bash "$@"
