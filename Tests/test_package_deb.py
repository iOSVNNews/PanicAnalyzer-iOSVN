import io
import pathlib
import plistlib
import subprocess
import sys
import tarfile
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]


def read_ar(path):
    data = path.read_bytes()
    assert data[:8] == b"!<arch>\n"
    cursor = 8
    entries = {}
    while cursor < len(data):
        header = data[cursor:cursor + 60]
        assert len(header) == 60 and header[-2:] == b"`\n"
        name = header[:16].decode().strip().rstrip("/")
        size = int(header[48:58].decode().strip())
        cursor += 60
        entries[name] = data[cursor:cursor + size]
        cursor += size + size % 2
    assert cursor == len(data)
    return entries


def main():
    base = pathlib.Path(tempfile.gettempdir()).resolve()
    with tempfile.TemporaryDirectory(prefix="panic-deb-") as directory:
        workspace = pathlib.Path(directory).resolve()
        assert workspace.is_relative_to(base)
        app = workspace / "PanicAnalyzer.app"
        app.mkdir()
        (app / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.iosvn.panicanalyzer",
            "CFBundleShortVersionString": "2.7.3",
            "CFBundleExecutable": "PanicAnalyzer",
        }))
        (app / "PanicAnalyzer").write_bytes(b"signed-arm64-fixture")
        (app / "PanicAnalyzer").chmod(0o755)
        for flags, expected_arch, expected_path in [
            (["--rootless"], "iphoneos-arm64", "var/jb/Applications/PanicAnalyzer.app"),
            ([], "iphoneos-arm", "Applications/PanicAnalyzer.app"),
            (["--scheme", "roothide"], "iphoneos-arm64e", "Applications/PanicAnalyzer.app"),
        ]:
            package = workspace / (expected_arch + ".deb")
            command = [sys.executable, str(ROOT / "scripts/package_deb.py"),
                       "--app", str(app), "--output", str(package)] + flags
            subprocess.run(command, check=True)
            members = read_ar(package)
            assert list(members) == ["debian-binary", "control.tar.gz", "data.tar.gz"]
            assert members["debian-binary"] == b"2.0\n"
            with tarfile.open(fileobj=io.BytesIO(members["control.tar.gz"]), mode="r:gz") as tar:
                control = tar.extractfile("control").read().decode()
                assert f"Architecture: {expected_arch}\n" in control
                assert "Version: 2.7.3\n" in control
                assert expected_path in tar.extractfile("postinst").read().decode()
            with tarfile.open(fileobj=io.BytesIO(members["data.tar.gz"]), mode="r:gz") as tar:
                binary = tar.getmember(expected_path + "/PanicAnalyzer")
                assert binary.mode & 0o111
                assert tar.extractfile(binary).read() == b"signed-arm64-fixture"
    print("DEB: rootless/rootful/roothide metadata, app paths and executable passed")


if __name__ == "__main__":
    main()
