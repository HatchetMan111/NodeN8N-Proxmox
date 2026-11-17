from localdash.metrics import collect_metrics


def test_collect_metrics_shape():
    data = collect_metrics()
    assert isinstance(data["cpu_percent"], float)
    assert isinstance(data["memory_percent"], float)
    assert isinstance(data["memory_used_mb"], float)
    assert isinstance(data["memory_total_mb"], float)
    assert isinstance(data["disk_percent"], float)
    assert isinstance(data["disk_used_gb"], float)
    assert isinstance(data["disk_total_gb"], float)
    assert isinstance(data["uptime_seconds"], int)
    assert isinstance(data["load_1m"], float)
    assert isinstance(data["hostname"], str)
    assert data["memory_total_mb"] > 0
    assert data["disk_total_gb"] > 0
