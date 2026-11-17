import os
import platform
import time

import psutil


def collect_metrics() -> dict:
    memory = psutil.virtual_memory()
    disk = psutil.disk_usage("/")
    load = os.getloadavg()
    return {
        "cpu_percent": round(psutil.cpu_percent(interval=None), 1),
        "memory_percent": round(memory.percent, 1),
        "memory_used_mb": round(memory.used / 1048576, 1),
        "memory_total_mb": round(memory.total / 1048576, 1),
        "disk_percent": round(disk.percent, 1),
        "disk_used_gb": round(disk.used / 1073741824, 2),
        "disk_total_gb": round(disk.total / 1073741824, 2),
        "uptime_seconds": int(time.time() - psutil.boot_time()),
        "load_1m": round(load[0], 2),
        "hostname": platform.node(),
    }
