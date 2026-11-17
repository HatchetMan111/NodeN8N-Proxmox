import { useCallback, useEffect, useState } from 'react';
import { fetchJSON, formatUptime } from './api';
import type { Health, MetricPoint, ServiceInfo, SystemMetrics } from './types';
import { MetricCard } from './components/MetricCard';
import { Sparkline } from './components/Sparkline';
import { ServiceTable } from './components/ServiceTable';

const HISTORY_LIMIT = 40;
const POLL_MS = 5000;

export default function App() {
  const [metrics, setMetrics] = useState<SystemMetrics | null>(null);
  const [services, setServices] = useState<ServiceInfo[]>([]);
  const [health, setHealth] = useState<Health | null>(null);
  const [history, setHistory] = useState<MetricPoint[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [updatedAt, setUpdatedAt] = useState<Date | null>(null);

  const refresh = useCallback(async () => {
    try {
      const [nextMetrics, nextServices, nextHealth] = await Promise.all([
        fetchJSON<SystemMetrics>('/api/system'),
        fetchJSON<{ services: ServiceInfo[] }>('/api/services'),
        fetchJSON<Health>('/api/health'),
      ]);
      setMetrics(nextMetrics);
      setServices(nextServices.services);
      setHealth(nextHealth);
      setHistory((previous) => [
        ...previous,
        {
          time: Date.now(),
          cpu: nextMetrics.cpu_percent,
          memory: nextMetrics.memory_percent,
        },
      ].slice(-HISTORY_LIMIT));
      setUpdatedAt(new Date());
      setError(null);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    }
  }, []);

  useEffect(() => {
    void refresh();
    const timer = window.setInterval(() => void refresh(), POLL_MS);
    return () => window.clearInterval(timer);
  }, [refresh]);

  const status = error ? 'offline' : health?.status === 'ok' ? 'online' : 'connecting';

  return (
    <div className="shell">
      <header className="topbar">
        <div className="brand">
          <span className="brand-mark">LD</span>
          <div>
            <h1>LocalDash</h1>
            <p>Lokales System- und Service-Dashboard</p>
          </div>
        </div>
        <div className="topbar-right">
          <span className={`status status-${status}`}>{status}</span>
          <span className="host">{metrics?.hostname ?? '—'}</span>
          <span className="version">v{health?.version ?? '—'}</span>
        </div>
      </header>

      {error && <div className="alert">API nicht erreichbar: {error} — neuer Versuch in 5 Sekunden.</div>}

      <main>
        <section className="section-head">
          <h2>Übersicht</h2>
          <span className="updated">
            {updatedAt ? `Aktualisiert ${updatedAt.toLocaleTimeString('de-DE')}` : 'Verbinde …'}
          </span>
        </section>

        <div className="grid">
          <MetricCard
            label="CPU-Auslastung"
            value={`${metrics?.cpu_percent.toFixed(1) ?? '—'} %`}
            detail={`Load (1m): ${metrics?.load_1m.toFixed(2) ?? '—'}`}
            percent={metrics?.cpu_percent}
            tone="cyan"
          >
            <Sparkline points={history} field="cpu" color="#3ddbd9" />
          </MetricCard>

          <MetricCard
            label="Arbeitsspeicher"
            value={`${metrics?.memory_used_mb.toFixed(0) ?? '—'} MB`}
            detail={`von ${metrics?.memory_total_mb.toFixed(0) ?? '—'} MB`}
            percent={metrics?.memory_percent}
            tone="violet"
          >
            <Sparkline points={history} field="memory" color="#a78bfa" />
          </MetricCard>

          <MetricCard
            label="Festplatte"
            value={`${metrics?.disk_used_gb.toFixed(1) ?? '—'} GB`}
            detail={`von ${metrics?.disk_total_gb.toFixed(1) ?? '—'} GB`}
            percent={metrics?.disk_percent}
            tone="green"
          />

          <MetricCard
            label="Laufzeit"
            value={metrics ? formatUptime(metrics.uptime_seconds) : '—'}
            detail="seit letztem Boot"
            tone="amber"
          />
        </div>

        <ServiceTable services={services} />
      </main>

      <footer>
        <span>LocalDash · vollständig lokal · keine Cloud-Dienste</span>
        <span>http://{metrics?.hostname ?? 'localdash'}:8080</span>
      </footer>
    </div>
  );
}
