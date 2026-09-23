#!/usr/bin/env python3
"""Package an already signed iOS .app for rootless or rootful jailbreaks."""

import argparse
import io
import pathlib
import plistlib
import tarfile


PACKAGE = "com.iosvn.panicanalyzer"


def tar_member(name, data, mode):
    info = tarfile.TarInfo(name)
    info.size = len(data)
    info.mode = mode
    info.uid = info.gid = info.mtime = 0
    info.uname = info.gname = "root"
    return info


def control_archive(version, architecture, install_path):
    control = (
        f"Package: {PACKAGE}\n"
        f"Version: {version}\n"
        f"Architecture: {architecture}\n"
        "Maintainer: iOSVN <76175332+iOSVNNews@users.noreply.github.com>\n"
        "Section: Applications\n"
        "Priority: optional\n"
        "Depends: firmware (>= 15.0)\n"
        "Description: PanicAnalyzer iPhone panic and crash log diagnostics\n"
    ).encode()
    scripts = {
        "postinst": f"#!/bin/sh\nif command -v uicache >/dev/null 2>&1; then uicache -p {install_path} || true; fi\nexit 0\n".encode(),
        "postrm": f"#!/bin/sh\nif command -v uicache >/dev/null 2>&1; then uicache -u {install_path} || true; fi\nexit 0\n".encode(),
    }
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode="w:gz", format=tarfile.GNU_FORMAT) as tar:
        tar.addfile(tar_member("control", control, 0o644), io.BytesIO(control))
        for name, data in scripts.items():
            tar.addfile(tar_member(name, data, 0o755), io.BytesIO(data))
    return out.getvalue()


def data_archive(app, install_path, executable_name):
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode="w:gz", format=tarfile.GNU_FORMAT) as tar:
        def normalize(info):
            info.uid = info.gid = info.mtime = 0
            info.uname = info.gname = "root"
            if info.isdir():
                info.mode = 0o755
            elif info.isfile():
                is_main_binary = info.name == install_path.lstrip("/") + "/" + executable_name
                info.mode = 0o755 if is_main_binary or info.mode & 0o111 else 0o644
            return info

        tar.add(str(app), arcname=install_path.lstrip("/"), recursive=True, filter=normalize)
    return out.getvalue()


def write_ar_member(out, name, data):
    encoded_name = (name + "/").encode("ascii")
    if len(encoded_name) > 16:
        raise ValueError(f"ar member name too long: {name}")
    header = (
        encoded_name.ljust(16)
        + b"0".ljust(12)
        + b"0".ljust(6)
        + b"0".ljust(6)
        + b"100644".ljust(8)
        + str(len(data)).encode().ljust(10)
        + b"`\n"
    )
    assert len(header) == 60
    out.write(header)
    out.write(data)
    if len(data) % 2:
        out.write(b"\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--rootless", action="store_true")
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    if not app.is_dir() or app.suffix != ".app":
        parser.error("--app must be a built iOS .app bundle")
    info = plistlib.loads((app / "Info.plist").read_bytes())
    if info.get("CFBundleIdentifier") != PACKAGE:
        parser.error("unexpected app bundle identifier")
    version = info["CFBundleShortVersionString"]
    executable_name = info["CFBundleExecutable"]
    if not (app / executable_name).is_file():
        parser.error("app main executable is missing")
    install_path = f"{'/var/jb' if args.rootless else ''}/Applications/{app.name}"
    architecture = "iphoneos-arm64" if args.rootless else "iphoneos-arm"
    members = (
        ("debian-binary", b"2.0\n"),
        ("control.tar.gz", control_archive(version, architecture, install_path)),
        ("data.tar.gz", data_archive(app, install_path, executable_name)),
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("wb") as output:
        output.write(b"!<arch>\n")
        for name, data in members:
            write_ar_member(output, name, data)
    print(f"Created {args.output} ({architecture}, {version}, {install_path})")


if __name__ == "__main__":
    main()
