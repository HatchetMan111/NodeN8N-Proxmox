import type { MetricPoint } from '../types';

interface SparklineProps {
  points: MetricPoint[];
  field: 'cpu' | 'memory';
  color: string;
}

export function Sparkline({ points, field, color }: SparklineProps) {
  if (points.length < 2) {
    return <div className="sparkline-empty">Daten werden gesammelt …</div>;
  }
  const values = points.map((point) => point[field]);
  const width = 240;
  const height = 56;
  const coordinates = values
    .map((value, index) => {
      const x = (index / (values.length - 1)) * width;
      const y = height - Math.min(Math.max(value, 0), 100) / 100 * height;
      return `${x.toFixed(1)},${y.toFixed(1)}`;
    })
    .join(' ');
  const last = values[values.length - 1];

  return (
    <svg className="sparkline" viewBox={`0 0 ${width} ${height}`} preserveAspectRatio="none" aria-label={`${field} history`}>
      <polyline points={`0,${height} ${coordinates} ${width},${height}`} fill={color} fillOpacity="0.12" stroke="none" />
      <polyline points={coordinates} fill="none" stroke={color} strokeWidth="2" vectorEffect="non-scaling-stroke" />
      <circle cx={width} cy={height - Math.min(Math.max(last, 0), 100) / 100 * height} r="3" fill={color} />
    </svg>
  );
}
