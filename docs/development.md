# Development Environment

The development tools come from the Nix flake at the repository root (`flake.nix` and `flake.lock`). The flake defines shells for `x86_64-linux` and `aarch64-linux`; only `x86_64-linux` has been run.

## Entering the Shell

```bash
nix develop
```

With direnv, run `direnv allow` once. The shell then loads whenever you enter the repository.

The shell provides Go, gopls, Odin, ols, odinfmt, and raylib. It sets `GOTOOLCHAIN=local`, so the `go` command never downloads another toolchain.

## Tool Versions

| Tool | Pinned by |
| --- | --- |
| Go | Minor version in `flake.nix` (`go_1_27`); patch version through `flake.lock` |
| Odin, ols, odinfmt, raylib, gopls | The nixpkgs revision in `flake.lock` |

`nix flake update` moves nixpkgs, and with it every tool except the Go minor version.

- Odin releases may break source compatibility. Treat a lock update that changes Odin's version as a code change: read the release notes and rebuild everything.
- `vendor:raylib` binds one raylib version, and linking a different one breaks the ABI without any error. The `raylib-binding` check in `nix flake check` fails when nixpkgs' raylib differs from the binding.

After changing `flake.nix` or `flake.lock`, run:

```bash
nix fmt
```

```bash
nix flake check --all-systems
```

## raylib Under Nix

- The upstream Odin distribution bundles prebuilt raylib libraries. nixpkgs' Odin deletes them and links `vendor:raylib` against the system raylib instead. The shell provides nixpkgs' raylib, and the shell's linker wrapper records its store path in the runpath of programs built there, so they run without `LD_LIBRARY_PATH`.
- nixpkgs' raylib uses nixpkgs' GLFW, which loads the X11, Wayland, and libGL libraries by store path. The GL drivers come from the system. On NixOS they are in `/run/opengl-driver` when `hardware.graphics.enable` is set. On other distributions they are not found without extra setup.
- nixpkgs' Odin also points `raygui` at a system library, which the shell does not provide. Programs that call no raygui procedures link without it.
- Programs built in the shell refer to store paths. They are for local development, not for distribution.

## Running Without a Display

A raylib program can be smoke-tested on a machine without a display, using a virtual X server and Mesa's software renderer from the pinned nixpkgs. Run this from the repository root, outside `nix develop`, and replace `./program` with the program to test:

```bash
mesa=$(nix build --no-link --print-out-paths --inputs-from . nixpkgs#mesa)
xvfb=$(nix build --no-link --print-out-paths --inputs-from . nixpkgs#xvfb-run)
LD_LIBRARY_PATH=$mesa/lib LIBGL_DRIVERS_PATH=$mesa/lib/dri \
  __EGL_VENDOR_LIBRARY_FILENAMES=$mesa/share/glvnd/egl_vendor.d/50_mesa.json \
  "$xvfb/bin/xvfb-run" -a -s '-screen 0 640x480x24' ./program
```

This exercises X11 with software rendering only. It says nothing about Wayland or about the GPU drivers of a real desktop.
