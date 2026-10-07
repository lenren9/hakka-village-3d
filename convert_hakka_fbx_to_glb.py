#!/usr/bin/env python
"""Convert a 3ds Max FBX file into a lightweight Three.js GLB.

The script intentionally avoids depending on the optional 3ds Max glTF
exporter. It uses the installed 3ds Max batch executable only as an FBX -> OBJ
bridge, then performs validation, optional quadric decimation, and GLB export
with trimesh.

Recommended installation:
    python -m pip install trimesh fast-simplification numpy pillow

Run from the outputs directory:
    python convert_hakka_fbx_to_glb.py

Or specify paths explicitly:
    python convert_hakka_fbx_to_glb.py ^
      --input hakka-village.fbx ^
      --output models/hakka-village.glb ^
      --target-faces 35000 ^
      --hard-max-faces 50000
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


DEFAULT_INPUT = "hakka-village.fbx"
DEFAULT_OUTPUT = "models/hakka-village.glb"
DEFAULT_TARGET_FACES = 35000
DEFAULT_HARD_MAX_FACES = 50000
MAXSCRIPT_TIMEOUT_SECONDS = 360


@dataclass
class ConversionStats:
    source_faces: int = 0
    source_meshes: int = 0
    exported_faces: int = 0
    exported_meshes: int = 0
    decimated: bool = False


def log(message: str) -> None:
    print(message, flush=True)


def fail(message: str, exit_code: int = 1) -> None:
    print(f"\nERROR: {message}", file=sys.stderr, flush=True)
    raise SystemExit(exit_code)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Convert 3ds Max FBX to a face-limited Three.js GLB."
    )
    parser.add_argument(
        "--input",
        default=DEFAULT_INPUT,
        help=f"Input FBX path. Default: {DEFAULT_INPUT}",
    )
    parser.add_argument(
        "--output",
        default=DEFAULT_OUTPUT,
        help=f"Output GLB path. Default: {DEFAULT_OUTPUT}",
    )
    parser.add_argument(
        "--target-faces",
        type=int,
        default=DEFAULT_TARGET_FACES,
        help=f"Preferred triangle budget. Default: {DEFAULT_TARGET_FACES}",
    )
    parser.add_argument(
        "--hard-max-faces",
        type=int,
        default=DEFAULT_HARD_MAX_FACES,
        help=f"Hard triangle limit. Default: {DEFAULT_HARD_MAX_FACES}",
    )
    parser.add_argument(
        "--reuse-obj",
        action="store_true",
        help="Reuse an existing intermediate OBJ instead of invoking 3ds Max.",
    )
    parser.add_argument(
        "--remove-intermediate",
        action="store_true",
        help="Remove the intermediate OBJ after a successful GLB export.",
    )
    return parser.parse_args()


def find_3dsmax_batch() -> Path | None:
    """Find 3dsmaxbatch.exe without hard-coding one specific installation."""
    candidates: list[Path] = []

    env_value = os.environ.get("THREEDSMAX_BATCH")
    if env_value:
        candidates.append(Path(env_value))

    for executable_name in ("3dsmaxbatch.exe", "3dsmaxbatch"):
        executable = shutil.which(executable_name)
        if executable:
            candidates.append(Path(executable))

    search_roots = [
        Path(r"C:\Program Files\Autodesk"),
        Path(r"C:\Program Files (x86)\Autodesk"),
        Path(r"D:\application\tools\3dsmax"),
        Path(r"D:\Autodesk"),
    ]

    for root in search_roots:
        if not root.exists():
            continue
        candidates.extend(root.glob("3ds Max */3dsmaxbatch.exe"))
        candidates.extend(root.glob("3ds Max */3dsmaxbatch"))

    for candidate in candidates:
        if candidate.is_file():
            return candidate.resolve()

    return None


def maxscript_quote(value: str | Path) -> str:
    text = str(value).replace("\\", "\\\\").replace('"', '\\"')
    return f'"{text}"'


def read_maxscript_log(log_path: Path) -> dict[str, str]:
    if not log_path.exists():
        return {}

    values: dict[str, str] = {}
    for line in log_path.read_text(encoding="utf-8", errors="ignore").splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        values[key.strip().upper()] = value.strip()
    return values


def run_maxscript_bridge(
    input_fbx: Path,
    intermediate_obj: Path,
    batch_exe: Path,
    temp_dir: Path,
) -> dict[str, str]:
    """Use 3ds Max batch mode to import FBX and export OBJ."""
    log_path = temp_dir / "fbx-to-obj.log"
    script_path = temp_dir / "fbx-to-obj.ms"

    # MAXScript's OBJ exporter is part of the standard 3ds Max installation.
    # Keeping this bridge in a temporary script makes the Python workflow
    # independent from the optional glTF exporter plugin.
    maxscript = f"""\
inputPath = {maxscript_quote(input_fbx)}
outputPath = {maxscript_quote(intermediate_obj)}
logPath = {maxscript_quote(log_path)}

resetMaxFile #noPrompt
importResult = importFile inputPath #noPrompt

geometryCount = 0
faceCount = 0
for obj in objects where superclassof obj == GeometryClass do
(
    geometryCount += 1
    try (faceCount += (getPolygonCount obj)[1]) catch ()
)

exportResult = exportFile outputPath #noPrompt
outStream = createFile logPath
format "IMPORT_RESULT: %\\n" (importResult as string) to:outStream
format "SOURCE_GEOMETRY_COUNT: %\\n" geometryCount to:outStream
format "SOURCE_FACE_COUNT: %\\n" faceCount to:outStream
format "EXPORT_RESULT: %\\n" (exportResult as string) to:outStream
format "FILE_EXISTS: %\\n" (doesFileExist outputPath) to:outStream
close outStream
"""

    script_path.write_text(maxscript, encoding="utf-8")

    command = [str(batch_exe), str(script_path), "-v", "3"]
    creation_flags = 0
    if os.name == "nt":
        creation_flags = getattr(subprocess, "CREATE_NO_WINDOW", 0)

    log(f"[1/4] Converting FBX to OBJ with 3ds Max batch: {input_fbx.name}")
    completed = subprocess.run(
        command,
        cwd=str(batch_exe.parent),
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="ignore",
        timeout=MAXSCRIPT_TIMEOUT_SECONDS,
        creationflags=creation_flags,
        check=False,
    )

    values = read_maxscript_log(log_path)
    if not values:
        details = (completed.stdout or "") + "\n" + (completed.stderr or "")
        details = details.replace("\x00", "").strip()
        fail(
            "3ds Max batch finished without a readable conversion log. "
            f"Command: {' '.join(command)}\n{details[-2000:]}"
        )

    if values.get("IMPORT_RESULT", "").lower() not in {"true", "1", "yes"}:
        fail(f"3ds Max could not import FBX: {input_fbx}")

    if values.get("EXPORT_RESULT", "").lower() not in {"true", "1", "yes"}:
        fail(
            "3ds Max could not export OBJ. Make sure the Wavefront OBJ exporter "
            "is enabled in Plug-in Manager."
        )

    if not intermediate_obj.exists():
        fail(f"3ds Max reported success, but the OBJ was not created: {intermediate_obj}")

    return values


def load_trimesh_scene(obj_path: Path):
    try:
        import trimesh
    except ImportError:
        fail(
            "trimesh is not installed. Run:\n"
            "  python -m pip install trimesh fast-simplification numpy pillow"
        )

    log(f"[2/4] Loading intermediate mesh: {obj_path.name}")
    loaded = trimesh.load(obj_path, force="scene", process=False)

    if isinstance(loaded, trimesh.Trimesh):
        scene = trimesh.Scene()
        scene.add_geometry(loaded, node_name="mesh")
        return scene

    if isinstance(loaded, trimesh.Scene):
        return loaded

    fail(f"trimesh returned an unsupported object: {type(loaded).__name__}")


def iter_meshes(scene) -> Iterable[tuple[str, object]]:
    for name, geometry in list(scene.geometry.items()):
        if hasattr(geometry, "faces") and len(geometry.faces) > 0:
            yield name, geometry


def count_faces(scene) -> tuple[int, int]:
    entries = list(iter_meshes(scene))
    return len(entries), sum(len(mesh.faces) for _, mesh in entries)


def simplify_mesh(mesh, target_faces: int):
    """Simplify one trimesh geometry while preserving its materials."""
    target_faces = max(4, int(target_faces))
    if target_faces >= len(mesh.faces):
        return mesh

    try:
        simplified = mesh.simplify_quadric_decimation(face_count=target_faces)
    except TypeError:
        simplified = mesh.simplify_quadric_decimation(target_faces)
    except Exception as exc:
        raise RuntimeError(f"quadric decimation failed: {exc}") from exc

    if simplified is None or not hasattr(simplified, "faces"):
        raise RuntimeError("quadric decimation returned no geometry")

    # Keep the original visual metadata on the simplified geometry.
    simplified.visual = mesh.visual
    return simplified


def decimate_scene(scene, target_faces: int, hard_max_faces: int) -> bool:
    mesh_count, total_faces = count_faces(scene)
    log(
        f"[3/4] Loaded {mesh_count} mesh groups with {total_faces:,} triangles. "
        f"Target budget: {target_faces:,}."
    )

    if total_faces <= target_faces:
        log("      Decimation is not required for this model.")
        return False

    original_total = total_faces
    ratio = target_faces / max(total_faces, 1)

    for name, mesh in iter_meshes(scene):
        requested = max(4, int(round(len(mesh.faces) * ratio)))
        if requested >= len(mesh.faces):
            continue
        try:
            scene.geometry[name] = simplify_mesh(mesh, requested)
        except RuntimeError as exc:
            log(f"      WARNING: kept {name} unchanged: {exc}")

    _, reduced_total = count_faces(scene)

    # A second proportional pass catches meshes that refused the first pass and
    # keeps the final result below the hard limit whenever topology permits.
    if reduced_total > hard_max_faces:
        second_ratio = hard_max_faces / max(reduced_total, 1)
        for name, mesh in iter_meshes(scene):
            requested = max(4, int(round(len(mesh.faces) * second_ratio)))
            if requested >= len(mesh.faces):
                continue
            try:
                scene.geometry[name] = simplify_mesh(mesh, requested)
            except RuntimeError as exc:
                log(f"      WARNING: kept {name} unchanged in second pass: {exc}")
        _, reduced_total = count_faces(scene)

    log(
        f"      Face count: {original_total:,} -> {reduced_total:,} "
        f"({(1 - reduced_total / original_total) * 100:.1f}% reduction)."
    )

    if reduced_total > hard_max_faces:
        fail(
            f"Decimation stopped at {reduced_total:,} triangles, above the hard "
            f"limit of {hard_max_faces:,}. Install fast-simplification or "
            "simplify the FBX before conversion."
        )

    return True


def export_glb(scene, output_glb: Path) -> None:
    output_glb.parent.mkdir(parents=True, exist_ok=True)
    log(f"[4/4] Writing GLB: {output_glb}")
    try:
        scene.export(output_glb, file_type="glb")
    except Exception as exc:
        fail(f"GLB export failed: {exc}")

    if not output_glb.exists() or output_glb.stat().st_size == 0:
        fail(f"GLB export produced no file: {output_glb}")


def main() -> None:
    args = parse_args()

    if args.target_faces < 1000:
        fail("--target-faces must be at least 1000.")
    if args.hard_max_faces < args.target_faces:
        fail("--hard-max-faces must be greater than or equal to --target-faces.")

    script_dir = Path(__file__).resolve().parent
    input_fbx = (script_dir / args.input).resolve() if not Path(args.input).is_absolute() else Path(args.input).resolve()
    output_glb = (script_dir / args.output).resolve() if not Path(args.output).is_absolute() else Path(args.output).resolve()

    if not input_fbx.exists():
        fail(f"Input FBX not found: {input_fbx}")

    intermediate_obj = script_dir / "hakka-village.intermediate.obj"
    temp_dir = Path(tempfile.mkdtemp(prefix="hakka-fbx-convert-"))
    stats = ConversionStats()

    try:
        batch_exe = find_3dsmax_batch()

        if args.reuse_obj and intermediate_obj.exists():
            log(f"[1/4] Reusing existing OBJ: {intermediate_obj.name}")
        elif batch_exe:
            bridge_values = run_maxscript_bridge(
                input_fbx=input_fbx,
                intermediate_obj=intermediate_obj,
                batch_exe=batch_exe,
                temp_dir=temp_dir,
            )
            stats.source_meshes = int(
                bridge_values.get("SOURCE_GEOMETRY_COUNT", "0") or 0
            )
            stats.source_faces = int(
                bridge_values.get("SOURCE_FACE_COUNT", "0") or 0
            )
            log(
                f"      3ds Max bridge: {stats.source_meshes} geometry objects, "
                f"{stats.source_faces:,} faces."
            )
        else:
            fail(
                "3dsmaxbatch.exe was not found. Set THREEDSMAX_BATCH to its full "
                "path, or convert the FBX to OBJ once and rerun with --reuse-obj."
            )

        scene = load_trimesh_scene(intermediate_obj)
        stats.exported_meshes, stats.source_faces = count_faces(scene)
        stats.decimated = decimate_scene(
            scene,
            target_faces=args.target_faces,
            hard_max_faces=args.hard_max_faces,
        )
        stats.exported_meshes, stats.exported_faces = count_faces(scene)
        export_glb(scene, output_glb)

        size_mb = output_glb.stat().st_size / (1024 * 1024)
        log("")
        log("Conversion completed successfully.")
        log(f"  Meshes: {stats.exported_meshes}")
        log(f"  Triangles: {stats.exported_faces:,}")
        log(f"  GLB size: {size_mb:.2f} MB")
        log(f"  Output: {output_glb}")
        if args.remove_intermediate and intermediate_obj.exists():
            intermediate_obj.unlink()
        elif intermediate_obj.exists():
            log(f"  Intermediate OBJ kept for inspection: {intermediate_obj}")
    finally:
        shutil.rmtree(temp_dir, ignore_errors=True)


if __name__ == "__main__":
    try:
        main()
    except subprocess.TimeoutExpired:
        fail(
            f"3ds Max batch timed out after {MAXSCRIPT_TIMEOUT_SECONDS} seconds. "
            "Close extra 3ds Max instances and retry."
        )
    except KeyboardInterrupt:
        fail("Conversion cancelled.")
