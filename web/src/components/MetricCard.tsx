import type { ReactNode } from 'react';

interface MetricCardProps {
  label: string;
  value: string;
  detail: string;
  percent?: number;
  tone?: 'cyan' | 'green' | 'violet' | 'amber';
  children?: ReactNode;
}

export function MetricCard({ label, value, detail, percent, tone = 'cyan', children }: MetricCardProps) {
  return (
    <article className={`card card-${tone}`}>
      <div className="card-top">
        <span className="card-label">{label}</span>
        {percent !== undefined && <span className="card-percent">{percent.toFixed(0)}%</span>}
      </div>
      <div className="card-value">{value}</div>
      <div className="card-detail">{detail}</div>
      {percent !== undefined && (
        <div className="bar"><div className="bar-fill" style={{ width: `${Math.min(Math.max(percent, 0), 100)}%` }} /></div>
      )}
      {children}
    </article>
  );
}
