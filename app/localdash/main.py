import os
from pathlib import Path

from fastapi import FastAPI
from fastapi.responses import FileResponse, JSONResponse

from .metrics import collect_metrics
from .services import list_services

VERSION = "1.0.0"
DEFAULT_STATIC_DIR = Path(
    os.environ.get(
        "LOCALDASH_STATIC_DIR",
        str(Path(__file__).resolve().parents[2] / "web" / "dist"),
    )
)


def create_app(static_dir: Path | None = None) -> FastAPI:
    application = FastAPI(title="LocalDash", version=VERSION)
    directory = Path(static_dir) if static_dir is not None else DEFAULT_STATIC_DIR
    root = directory.resolve()

    @application.get("/api/health")
    def health() -> dict:
        return {"status": "ok", "version": VERSION}

    @application.get("/api/system")
    def system() -> dict:
        return collect_metrics()

    @application.get("/api/services")
    def services() -> dict:
        return {"services": list_services()}

    if root.is_dir():

        @application.get("/{full_path:path}")
        def spa(full_path: str):
            candidate = (root / full_path).resolve()
            if candidate.is_relative_to(root) and candidate.is_file():
                return FileResponse(candidate)
            index = root / "index.html"
            if index.is_file():
                return FileResponse(index)
            return JSONResponse({"detail": "Not Found"}, status_code=404)

    return application


app = create_app()
