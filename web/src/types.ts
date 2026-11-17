export interface SystemMetrics {
  cpu_percent: number;
  memory_percent: number;
  memory_used_mb: number;
  memory_total_mb: number;
  disk_percent: number;
  disk_used_gb: number;
  disk_total_gb: number;
  uptime_seconds: number;
  load_1m: number;
  hostname: string;
}

export interface ServiceInfo {
  name: string;
  active: string;
  sub: string;
}

export interface Health {
  status: string;
  version: string;
}

export interface MetricPoint {
  time: number;
  cpu: number;
  memory: number;
}
