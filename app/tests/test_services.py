import subprocess

from localdash import services


def test_list_services_parses_output(monkeypatch):
    output = "localdash.service loaded active running LocalDash\nssh.service loaded active running SSH\n"

    def fake_run(*args, **kwargs):
        return subprocess.CompletedProcess(args, 0, stdout=output, stderr="")

    monkeypatch.setattr(services.subprocess, "run", fake_run)
    assert services.list_services() == [
        {"name": "localdash.service", "active": "active", "sub": "running"},
        {"name": "ssh.service", "active": "active", "sub": "running"},
    ]


def test_list_services_ignores_non_services(monkeypatch):
    output = "systemd-journald.service loaded active running Journal\nsome.target loaded active active Target\n"

    def fake_run(*args, **kwargs):
        return subprocess.CompletedProcess(args, 0, stdout=output, stderr="")

    monkeypatch.setattr(services.subprocess, "run", fake_run)
    assert services.list_services() == [
        {"name": "systemd-journald.service", "active": "active", "sub": "running"}
    ]


def test_list_services_returns_empty_on_missing_systemctl(monkeypatch):
    def fake_run(*args, **kwargs):
        raise FileNotFoundError("systemctl")

    monkeypatch.setattr(services.subprocess, "run", fake_run)
    assert services.list_services() == []


def test_list_services_returns_empty_on_nonzero_exit(monkeypatch):
    def fake_run(*args, **kwargs):
        return subprocess.CompletedProcess(args, 1, stdout="", stderr="failed")

    monkeypatch.setattr(services.subprocess, "run", fake_run)
    assert services.list_services() == []
