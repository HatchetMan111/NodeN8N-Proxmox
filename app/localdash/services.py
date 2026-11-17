import subprocess


LIST_COMMAND = [
    "systemctl",
    "list-units",
    "--type=service",
    "--all",
    "--no-pager",
    "--plain",
    "--no-legend",
]


def list_services() -> list[dict]:
    try:
        result = subprocess.run(
            LIST_COMMAND,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    if result.returncode != 0:
        return []
    services = []
    for line in result.stdout.splitlines():
        parts = line.split()
        if len(parts) < 4 or not parts[0].endswith(".service"):
            continue
        services.append(
            {"name": parts[0], "active": parts[2], "sub": parts[3]}
        )
    return services
