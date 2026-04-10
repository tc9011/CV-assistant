#!/usr/bin/env bash
set -euo pipefail

# Local LLM binaries are macOS-only — skip on Linux/Windows
if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Skipping llama-server download (not macOS)."
  exit 0
fi

LLAMA_VERSION="b8740"
RELEASE_BASE="https://github.com/ggml-org/llama.cpp/releases/download/${LLAMA_VERSION}"

TARGET_DIR="$(cd "$(dirname "$0")/.." && pwd)/resources"

download_arch() {
  local arch="$1"
  local platform_suffix

  case "${arch}" in
    arm64)  platform_suffix="macos-arm64" ;;
    x86_64) platform_suffix="macos-x64"   ;;
    *)
      echo "ERROR: Unsupported architecture: ${arch}"
      return 1
      ;;
  esac

  local binary_name="llama-server-${arch}"
  local target_path="${TARGET_DIR}/${binary_name}"

  if [[ -f "${target_path}" ]]; then
    local missing_dylibs=false
    for critical in libllama libggml libmtmd; do
      if ! compgen -G "${TARGET_DIR}/${critical}*.dylib" > /dev/null 2>&1; then
        missing_dylibs=true
        echo "⚠ ${binary_name} exists but ${critical}.dylib is missing — re-downloading..."
        break
      fi
    done
    if [[ "${missing_dylibs}" == "false" ]]; then
      echo "✓ ${binary_name} and critical dylibs already exist at ${TARGET_DIR}"
      return 0
    fi
    rm -f "${target_path}"
    rm -f "${TARGET_DIR}/"lib*.dylib
  fi

  local archive_name="llama-${LLAMA_VERSION}-bin-${platform_suffix}.tar.gz"
  local download_url="${RELEASE_BASE}/${archive_name}"
  local temp_dir
  temp_dir=$(mktemp -d)

  echo "Downloading ${archive_name} for ${arch}..."
  curl -fSL -o "${temp_dir}/${archive_name}" "${download_url}"

  echo "Extracting llama-server and dependencies..."
  tar xzf "${temp_dir}/${archive_name}" -C "${temp_dir}"

  # b8740 archive extracts to llama-b8740/ with flat layout (no bin/ or lib/ subdirs)
  local extracted_dir="${temp_dir}/llama-${LLAMA_VERSION}"

  if [[ ! -d "${extracted_dir}" ]]; then
    extracted_dir=$(find "${temp_dir}" -maxdepth 1 -type d -name "llama-*" | head -1)
    if [[ -z "${extracted_dir}" ]]; then
      echo "ERROR: Could not find extracted llama directory in archive"
      rm -rf "${temp_dir}"
      return 1
    fi
  fi

  # b8740 flat layout: llama-server sits in root; older formats use bin/ subdir
  local server_bin="${extracted_dir}/llama-server"
  if [[ ! -f "${server_bin}" && -f "${extracted_dir}/bin/llama-server" ]]; then
    server_bin="${extracted_dir}/bin/llama-server"
  fi

  if [[ ! -f "${server_bin}" ]]; then
    echo "ERROR: llama-server binary not found in archive"
    rm -rf "${temp_dir}"
    return 1
  fi

  mv "${server_bin}" "${target_path}"
  chmod +x "${target_path}"

  # Collect dylibs — flat layout (b8740) or lib/ subdir (older formats)
  # IMPORTANT: The archive ships versioned symlink chains (e.g. libggml.dylib →
  # libggml.0.dylib → libggml.0.9.11.dylib). @electron/universal's ASAR merge
  # fails with EEXIST when recreating these symlinks. We flatten the chain:
  # copy only the real (non-symlink) dylib and rename it to the soname that the
  # binary actually loads (the .0.dylib form, matching otool -L output).
  local dylib_source="${extracted_dir}"
  if ! compgen -G "${extracted_dir}/lib*.dylib" > /dev/null 2>&1; then
    if [[ -d "${extracted_dir}/lib" ]]; then
      dylib_source="${extracted_dir}/lib"
    fi
  fi

  for f in "${dylib_source}/"lib*.dylib; do
    [[ -e "$f" ]] || continue
    # Skip symlinks — we only want the real versioned file
    [[ -L "$f" ]] && continue
    local base
    base=$(basename "$f")
    # Extract soname (the .0.dylib form) from the binary's install name
    local soname
    soname=$(otool -D "$f" 2>/dev/null | tail -1 | xargs basename 2>/dev/null || true)
    if [[ -z "${soname}" || "${soname}" == "${base}" ]]; then
      # Fallback: if otool fails or returns the same name, use as-is
      soname="${base}"
    fi
    if [[ -e "${TARGET_DIR}/${soname}" ]]; then
      continue
    fi
    cp "$f" "${TARGET_DIR}/${soname}"
  done

  codesign --force --sign - "${target_path}" 2>/dev/null || echo "Warning: codesign failed for binary (non-fatal)"
  for dylib in "${TARGET_DIR}/"lib*.dylib; do
    [[ -f "$dylib" ]] || continue
    codesign --force --sign - "$dylib" 2>/dev/null || echo "Warning: codesign failed for $(basename "$dylib") (non-fatal)"
  done

  rm -rf "${temp_dir}"
  echo "✓ Installed ${binary_name} to ${target_path}"
}

mkdir -p "${TARGET_DIR}"

if [[ "${1:-}" == "--all-arch" ]]; then
  echo "Downloading llama-server for all macOS architectures..."
  download_arch "arm64"
  download_arch "x86_64"
else
  ARCH=$(uname -m)
  download_arch "${ARCH}"
fi

echo "Done."
