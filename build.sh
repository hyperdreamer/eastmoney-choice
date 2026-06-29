#!/bin/bash
# Choice Financial Terminal — AppImage build, check & update script
#   build  — force download + build AppImage
#   check  — check if a newer version is available on CDN
#   update — check, download & build only if newer
#   clean  — remove build artifacts
set -euo pipefail

# ── Configuration ──────────────────────────────────────────────
SCRIPT_DIR="${SCRIPT_DIR:-$HOME/Development/eastmoney-choice}"
CDN_BASE="https://choice-app.eastmoney.com/choice/OfflinePackage"
DISTROS=("uos" "kylin" "fangd")
ARCH="${ARCH:-x86}"
APPIMAGETOOL_URL="https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage"

# ── Colors ─────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }

# ── Ensure tools ───────────────────────────────────────────────
ensure_appimagetool() {
    local at="$SCRIPT_DIR/appimagetool"
    if [[ -x "$at" ]]; then return 0; fi
    info "Downloading appimagetool..."
    curl -sL "$APPIMAGETOOL_URL" -o "$at"
    chmod +x "$at"
    ok "appimagetool ready"
}

ensure_deps() {
    local missing=()
    for cmd in ar patchelf curl; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Missing: ${missing[*]}"
        err "Install with: sudo pacman -S binutils patchelf curl"
        exit 1
    fi
    ensure_appimagetool
}

# ── Discover latest .deb URL ───────────────────────────────────
discover_deb_url() {
    for distro in "${DISTROS[@]}"; do
        local url="${CDN_BASE}/ChoiceSetup_${distro}_${ARCH}.deb"
        local code
        code=$(curl -sIL --max-time 10 -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)
        if [[ "$code" == "200" ]]; then
            echo "$url"
            return 0
        fi
    done
    err "No Linux x86_64 .deb found on CDN (tried: ${DISTROS[*]})"
    return 1
}

# ── Extract version from .deb control file ─────────────────────
extract_version() {
    local deb="$1"
    local tmpdir
    tmpdir=$(mktemp -d)
    (
        cd "$tmpdir"
        ar x "$deb" control.tar.xz 2>/dev/null
        tar xf control.tar.xz 2>/dev/null
        grep '^Version:' control | awk '{print $2}'
    )
    rm -rf "$tmpdir"
}

# ── Check for update (downloads .deb, compares version) ────────
do_check() {
    mkdir -p "$SCRIPT_DIR"
    local local_ver=""
    [[ -f "$SCRIPT_DIR/.version" ]] && local_ver=$(cat "$SCRIPT_DIR/.version")

    info "Discovering latest .deb URL..."
    local deb_url
    deb_url=$(discover_deb_url) || return 1
    ok "Found: $deb_url"

    info "Downloading .deb to check version (~230 MB)..."
    local tmp_deb="$SCRIPT_DIR/.tmp_check.deb"
    curl -sL --max-time 120 -o "$tmp_deb" "$deb_url" || { err "Download failed"; rm -f "$tmp_deb"; return 1; }

    local remote_ver
    remote_ver=$(extract_version "$tmp_deb")
    info "Local:  ${local_ver:-none}"
    info "Remote: $remote_ver"

    if [[ -z "$local_ver" ]]; then
        warn "No local build yet. Run '$0 build' to create one."
        rm -f "$tmp_deb"
        return 0
    fi

    if [[ "$remote_ver" == "$local_ver" ]]; then
        ok "Up to date! ($local_ver)"
        rm -f "$tmp_deb"
        return 0
    fi

    info "New version available: $local_ver → $remote_ver"
    info "Run '$0 update' to build it."
    rm -f "$tmp_deb"
    return 0
}

# ── Build AppImage ─────────────────────────────────────────────
do_build() {
    mkdir -p "$SCRIPT_DIR"
    ensure_deps

    local deb_url force_dl="${1:-}"
    if [[ -n "${2:-}" ]]; then force_dl="$2"; fi

    info "Discovering .deb URL..."
    deb_url=$(discover_deb_url) || return 1
    ok "Source: $deb_url"

    # Download
    local build_dir="$SCRIPT_DIR/build"
    rm -rf "$build_dir"
    mkdir -p "$build_dir"

    local deb_file="$build_dir/choice.deb"
    local cached="$SCRIPT_DIR/.tmp_check.deb"

    if [[ "$force_dl" != "--force-download" && -f "$cached" ]]; then
        info "Reusing cached .deb from check..."
        mv "$cached" "$deb_file"
    else
        rm -f "$cached"
        info "Downloading .deb (~230 MB)..."
        curl -L --max-time 300 --progress-bar -o "$deb_file" "$deb_url" || { err "Download failed"; return 1; }
    fi
    ok "Downloaded: $(du -h "$deb_file" | cut -f1)"

    # Extract version
    local version
    version=$(extract_version "$deb_file")
    ok "Version: $version"

    # Extract .deb
    info "Extracting..."
    local appdir="$build_dir/AppDir"
    rm -rf "$appdir"
    mkdir -p "$appdir"
    (
        cd "$appdir"
        ar x "$deb_file"
        tar xf data.tar.xz
    )
    ok "Extracted"

    # Patch Qt sonames (suppress non-ELF noise)
    info "Patching Qt sonames..."
    (
        cd "$appdir/opt/apps/com.eastmoney.choice/files"
        bash changeQtNeed.sh 2>/dev/null || true
    )
    ok "Qt sonames patched"

    # ── AppDir metadata ──
    cd "$appdir"

    cat > AppRun << 'APPRUN'
#!/bin/bash
SELF="$(readlink -f "$0")"
APPDIR="$(dirname "$SELF")"
APPFILES="$APPDIR/opt/apps/com.eastmoney.choice/files"
export LD_LIBRARY_PATH="$APPFILES/lib:$APPFILES:$LD_LIBRARY_PATH"
export QT_PLUGIN_PATH="$APPFILES/plugins"
exec "$APPFILES/EMChoice" "$@"
APPRUN
    chmod +x AppRun

    cat > choice.desktop << DESKTOP
[Desktop Entry]
Name=Choice金融终端
Name[en]=Choice Financial Terminal
Comment=East Money Choice Smart Financial Terminal
Exec=AppRun
Icon=choice
Type=Application
Categories=Office;Finance;
Terminal=false
X-AppImage-Version=${version}
DESKTOP

    cp opt/apps/com.eastmoney.choice/entries/icons/hicolor/256x256/apps/com.eastmoney.choice.png choice.png

    # ── Build AppImage ──
    info "Building AppImage..."
    local output="$SCRIPT_DIR/Choice-${version}-x86_64.AppImage"
    cd "$build_dir"
    "$SCRIPT_DIR/appimagetool" AppDir "$output" 2>&1 | grep -E 'Success|error|warning' || true

    # Save metadata
    echo "$version" > "$SCRIPT_DIR/.version"
    echo "$deb_url" > "$SCRIPT_DIR/.source_url"

    # Cleanup
    rm -rf "$build_dir"

    local size
    size=$(du -h "$output" | cut -f1)
    ok "──────────────────────────────────────────────"
    ok "AppImage: $output"
    ok "Size:     $size"
    ok "Version:  $version"
    ok "──────────────────────────────────────────────"
    echo ""
    info "Runtime deps (Arch): sudo pacman -S gtk3 glib2 cairo pango gdk-pixbuf2 at-spi2-core libxi libx11 mesa"
    echo ""
    warn "Known issue: libpng warnings on login verification window."
    warn "Qt 5.14.2's bundled libpng is old. Image still loads — console noise only."
    echo ""
    info "Run: $output"
}

# ── Update ─────────────────────────────────────────────────────
do_update() {
    info "Checking for updates..."
    mkdir -p "$SCRIPT_DIR"

    local deb_url
    deb_url=$(discover_deb_url) || return 1

    local tmp_deb="$SCRIPT_DIR/.tmp_check.deb"
    curl -sL --max-time 120 -o "$tmp_deb" "$deb_url" || { err "Download failed"; rm -f "$tmp_deb"; return 1; }

    local remote_ver local_ver=""
    remote_ver=$(extract_version "$tmp_deb")
    [[ -f "$SCRIPT_DIR/.version" ]] && local_ver=$(cat "$SCRIPT_DIR/.version")

    info "Local:  ${local_ver:-none}"
    info "Remote: $remote_ver"

    if [[ "$remote_ver" == "$local_ver" ]]; then
        ok "Already up to date ($local_ver)"
        rm -f "$tmp_deb"
        return 0
    fi

    info "Update available: ${local_ver:-none} → $remote_ver"
    info "Building..."
    do_build  # reuses $SCRIPT_DIR/.tmp_check.deb
}

# ── Clean ──────────────────────────────────────────────────────
do_clean() {
    rm -rf "$SCRIPT_DIR/build" "$SCRIPT_DIR/.tmp_check.deb" \
           "$SCRIPT_DIR/squashfs-root"
    ok "Cleaned build artifacts"
}

# ── Main ───────────────────────────────────────────────────────
cmd="${1:-build}"
case "$cmd" in
    build)   do_build "$@" ;;
    check)   do_check ;;
    update)  do_update ;;
    clean)   do_clean ;;
    *)
        echo "Usage: $0 {build|check|update|clean}"
        echo ""
        echo "  build   Force download + build AppImage"
        echo "  check   Check if newer version available on CDN"
        echo "  update  Check + build only if newer version exists"
        echo "  clean   Remove build artifacts"
        echo ""
        echo "Config: ~/Development/eastmoney-choice/"
        exit 1
        ;;
esac
