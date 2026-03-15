#!/usr/bin/env bash
set -euo pipefail

# bundle_python.sh — Build a minimal stripped Python runtime for bundling inside Muesli.app
#
# Takes the existing .venv at the repo root and produces a self-contained
# dist-native/python-runtime/ with only the packages needed by bridge/worker.py
# (mlx-whisper transcription via the Python backend).

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$ROOT/.venv"
OUTPUT="$ROOT/dist-native/python-runtime"
PYTHON_VERSION="3.13"

if [[ ! -d "$VENV" ]]; then
    echo "Error: venv not found at $VENV" >&2
    exit 1
fi

# Resolve the base Python prefix (where the stdlib lives).
# In a venv the stdlib is at the *base* prefix, not inside .venv/.
PYTHON_BIN="$VENV/bin/python${PYTHON_VERSION}"
if [[ ! -f "$PYTHON_BIN" ]]; then
    # Fall back to unversioned binary
    PYTHON_BIN="$VENV/bin/python"
fi

if [[ ! -f "$PYTHON_BIN" ]]; then
    echo "Error: Python binary not found in $VENV/bin/" >&2
    exit 1
fi

BASE_PREFIX="$("$PYTHON_BIN" -c 'import sys; print(sys.base_prefix)')"
echo "Python base prefix: $BASE_PREFIX"
echo "Python version:     $PYTHON_VERSION"

STDLIB_SRC="$BASE_PREFIX/lib/python${PYTHON_VERSION}"
SITE_PACKAGES_SRC="$VENV/lib/python${PYTHON_VERSION}/site-packages"

if [[ ! -d "$STDLIB_SRC" ]]; then
    echo "Error: stdlib not found at $STDLIB_SRC" >&2
    exit 1
fi

if [[ ! -d "$SITE_PACKAGES_SRC" ]]; then
    echo "Error: site-packages not found at $SITE_PACKAGES_SRC" >&2
    exit 1
fi

echo "Creating stripped Python runtime at $OUTPUT ..."
rm -rf "$OUTPUT"
mkdir -p "$OUTPUT/bin" "$OUTPUT/lib/python${PYTHON_VERSION}"

# ---------------------------------------------------------------------------
# 1. Copy Python binary
# ---------------------------------------------------------------------------
echo "  Copying Python binary..."
cp "$PYTHON_BIN" "$OUTPUT/bin/python${PYTHON_VERSION}"
chmod +x "$OUTPUT/bin/python${PYTHON_VERSION}"
ln -sf "python${PYTHON_VERSION}" "$OUTPUT/bin/python3"
ln -sf "python${PYTHON_VERSION}" "$OUTPUT/bin/python"

# Copy linked dylibs that live inside the Python framework/prefix.
# On conda/Homebrew installs the libpython dylib is needed at runtime.
for dylib in "$BASE_PREFIX"/lib/libpython*.dylib; do
    if [[ -f "$dylib" ]]; then
        echo "  Copying $(basename "$dylib")"
        cp "$dylib" "$OUTPUT/lib/"
    fi
done

# Copy SSL libraries (needed by _ssl extension for HTTPS model downloads)
for lib in "$BASE_PREFIX"/lib/libssl*.dylib "$BASE_PREFIX"/lib/libcrypto*.dylib; do
    if [[ -f "$lib" ]]; then
        echo "  Copying $(basename "$lib")"
        cp "$lib" "$OUTPUT/lib/"
    fi
done

# ---------------------------------------------------------------------------
# 2. Copy standard library (minimal — .py + lib-dynload .so, skip tests)
# ---------------------------------------------------------------------------
echo "  Copying standard library..."
STDLIB_DST="$OUTPUT/lib/python${PYTHON_VERSION}"

# Only copy actual stdlib modules (not conda-installed packages that live in the same dir).
# We use Python itself to list the stdlib module names.
STDLIB_MODULES=$("$PYTHON_BIN" -c '
import sys, os, pkgutil
stdlib_path = [p for p in sys.path if "site-packages" not in p and "lib/python" in p]
names = set()
for p in stdlib_path:
    if not os.path.isdir(p): continue
    for entry in os.listdir(p):
        full = os.path.join(p, entry)
        if entry.startswith("_") or entry.endswith(".py") or (os.path.isdir(full) and os.path.exists(os.path.join(full, "__init__.py"))):
            name = entry.replace(".py", "")
            names.add(name)
for n in sorted(names):
    print(n)
')

# Copy only stdlib .py files at the top level + stdlib subdirectories
for entry in $STDLIB_MODULES; do
    src_file="$STDLIB_SRC/${entry}.py"
    src_dir="$STDLIB_SRC/${entry}"
    if [[ -f "$src_file" ]]; then
        cp "$src_file" "$STDLIB_DST/"
    fi
    if [[ -d "$src_dir" ]]; then
        rsync -a \
            --exclude="__pycache__/" \
            --exclude="*.pyc" \
            --exclude="test/" \
            --exclude="tests/" \
            "$src_dir/" "$STDLIB_DST/${entry}/"
    fi
done

# Copy lib-dynload (compiled C extensions: _json, _ssl, _sqlite3, etc.)
if [[ -d "$STDLIB_SRC/lib-dynload" ]]; then
    echo "  Copying lib-dynload..."
    mkdir -p "$STDLIB_DST/lib-dynload"
    rsync -a "$STDLIB_SRC/lib-dynload/" "$STDLIB_DST/lib-dynload/"
fi

# ---------------------------------------------------------------------------
# 3. Copy only essential site-packages
# ---------------------------------------------------------------------------
echo "  Copying essential site-packages..."
SITE_DST="$STDLIB_DST/site-packages"
mkdir -p "$SITE_DST"

# Essential packages — directory names as they appear in site-packages.
# Note: pyyaml installs as yaml/ and _yaml/, tiktoken needs tiktoken_ext/.
ESSENTIAL_PACKAGES=(
    mlx
    mlx_whisper
    numpy
    tiktoken
    tiktoken_ext
    huggingface_hub
    httpx
    httpcore
    h11
    anyio
    idna
    charset_normalizer
    tqdm
    more_itertools
    regex
    requests
    urllib3
    certifi
    filelock
    fsspec
    safetensors
    yaml
    _yaml
    packaging
    tokenizers
    hf_xet
    jellyfish
)

for pkg in "${ESSENTIAL_PACKAGES[@]}"; do
    src="$SITE_PACKAGES_SRC/$pkg"
    if [[ -d "$src" ]]; then
        echo "    $pkg/"
        rsync -a \
            --exclude="__pycache__/" \
            --exclude="*.pyc" \
            --exclude="test/" \
            --exclude="tests/" \
            "$src/" "$SITE_DST/$pkg/"
    elif ls "$SITE_PACKAGES_SRC"/${pkg}*.so 2>/dev/null | head -1 >/dev/null; then
        # Single-file .so extension (e.g. tokenizers)
        for f in "$SITE_PACKAGES_SRC"/${pkg}*.so; do
            echo "    $(basename "$f")"
            cp "$f" "$SITE_DST/"
        done
    elif [[ -f "$SITE_PACKAGES_SRC/${pkg}.py" ]]; then
        echo "    ${pkg}.py"
        cp "$SITE_PACKAGES_SRC/${pkg}.py" "$SITE_DST/"
    else
        echo "    WARNING: $pkg not found in site-packages (skipped)"
    fi
done

# Copy .dist-info directories for essential packages (needed by importlib.metadata).
# We match on package name prefix to catch hyphenated dist names.
DIST_INFO_PREFIXES=(
    mlx- mlx_whisper mlx_metal
    numpy
    tiktoken
    huggingface_hub
    httpx httpcore h11 anyio idna charset_normalizer
    tqdm
    more_itertools
    regex
    requests
    urllib3
    certifi
    filelock
    fsspec
    safetensors
    pyyaml PyYAML
    packaging
    tokenizers
    hf_xet
    jellyfish
)

for prefix in "${DIST_INFO_PREFIXES[@]}"; do
    for di in "$SITE_PACKAGES_SRC"/${prefix}*.dist-info; do
        if [[ -d "$di" ]]; then
            dirname="$(basename "$di")"
            echo "    $dirname"
            rsync -a "$di/" "$SITE_DST/$dirname/"
        fi
    done
done

# ---------------------------------------------------------------------------
# 3b. Patch mlx_whisper/timing.py to make numba/scipy optional
# ---------------------------------------------------------------------------
TIMING_FILE="$SITE_DST/mlx_whisper/timing.py"
if [[ -f "$TIMING_FILE" ]]; then
    echo "  Patching timing.py (numba/scipy optional)..."
    "$PYTHON_BIN" -c "
path = '$TIMING_FILE'
with open(path) as f:
    content = f.read()
content = content.replace(
    'import numba\nimport numpy as np\nfrom scipy import signal',
    '''import numpy as np
try:
    import numba
except ImportError:
    class _NumbaStub:
        @staticmethod
        def jit(*args, **kwargs):
            def decorator(fn):
                return fn
            if args and callable(args[0]):
                return args[0]
            return decorator
    numba = _NumbaStub()
try:
    from scipy import signal
except ImportError:
    signal = None'''
)
with open(path, 'w') as f:
    f.write(content)
"
fi

# ---------------------------------------------------------------------------
# 4. Clean up: strip .pyc, __pycache__, test dirs
# ---------------------------------------------------------------------------
echo "  Cleaning up..."
find "$OUTPUT" -name "__pycache__" -type d -exec rm -rf {} + 2>/dev/null || true
find "$OUTPUT" -name "*.pyc" -delete 2>/dev/null || true
find "$OUTPUT" -name "test" -type d -exec rm -rf {} + 2>/dev/null || true
find "$OUTPUT" -name "tests" -type d -exec rm -rf {} + 2>/dev/null || true

# Remove .pyi stub files (type hints, not needed at runtime)
find "$OUTPUT" -name "*.pyi" -delete 2>/dev/null || true

# Remove empty directories left behind after cleanup
find "$OUTPUT" -type d -empty -delete 2>/dev/null || true

# ---------------------------------------------------------------------------
# 5. Report
# ---------------------------------------------------------------------------
TOTAL_SIZE="$(du -sh "$OUTPUT" | cut -f1)"
echo ""
echo "Stripped Python runtime: $TOTAL_SIZE"
echo "Location: $OUTPUT"
echo ""
echo "Contents:"
du -sh "$OUTPUT/bin" "$OUTPUT/lib/libpython"*.dylib "$OUTPUT/lib/python${PYTHON_VERSION}" 2>/dev/null || true
echo ""
echo "Site-packages:"
du -sh "$SITE_DST"/*/ 2>/dev/null | sort -rh | head -20
