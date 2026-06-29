# Choice Financial Terminal — AppImage Builder

Build, check, and update an [AppImage](https://appimage.org/) of **East Money Choice** (东方财富Choice金融终端) for Arch Linux.

## Quick Start

```bash
# Check if a newer version is available
./build.sh check

# Build the AppImage
./build.sh build

# Or do both: check + build only if newer
./build.sh update

# Clean up build artifacts
./build.sh clean
```

## Requirements (Arch Linux)

```bash
sudo pacman -S binutils patchelf curl
```

**Runtime dependencies** (already on any desktop Arch):
```bash
sudo pacman -S gtk3 glib2 cairo pango gdk-pixbuf2 at-spi2-core libxi libx11 mesa
```

## How It Works

1. Probes East Money's CDN for the latest `.deb` (uos → kylin → fangd, x86_64)
2. Extracts the `.deb`, patches Qt 5.14.2 sonames to use bundled libraries
3. Packages everything into a portable AppImage via `appimagetool`

## Known Issues

- **libpng warnings on login verification window** — Qt 5.14.2's bundled libpng is old. The image still loads; console noise only.

## License

This script is for personal use. Choice Financial Terminal is proprietary software by East Money (东方财富).
