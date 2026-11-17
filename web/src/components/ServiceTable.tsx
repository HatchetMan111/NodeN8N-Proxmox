import type { ServiceInfo } from '../types';

interface ServiceTableProps {
  services: ServiceInfo[];
}

export function ServiceTable({ services }: ServiceTableProps) {
  return (
    <div className="panel">
      <div className="panel-head">
        <h2>Systemd-Dienste</h2>
        <span className="panel-meta">{services.length} Dienste im Container</span>
      </div>
      {services.length === 0 ? (
        <p className="empty">Keine Dienste gefunden oder systemd nicht verfügbar.</p>
      ) : (
        <div className="table-wrap">
          <table>
            <thead>
              <tr><th>Dienst</th><th>Status</th><th>Zustand</th></tr>
            </thead>
            <tbody>
              {services.map((service) => (
                <tr key={service.name}>
                  <td className="service-name">{service.name}</td>
                  <td>
                    <span className={`badge badge-${service.active === 'active' ? 'active' : 'inactive'}`}>
                      {service.active}
                    </span>
                  </td>
                  <td className="muted">{service.sub}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
