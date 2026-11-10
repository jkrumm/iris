import type { StatSpec } from "../spec";

function Delta({ delta }: { delta: number }) {
  const tone = delta > 0 ? "good" : delta < 0 ? "bad" : "flat";
  const arrow = delta > 0 ? "▲" : delta < 0 ? "▼" : "▬";
  return (
    <div className={`stat-delta ${tone}`}>
      <span aria-hidden="true">{arrow}</span> {delta > 0 ? "+" : ""}
      {delta}
    </div>
  );
}

export function StatView({ spec }: { spec: StatSpec }) {
  return (
    <div className="stat-grid">
      {spec.items.map((item, index) => (
        <div className="stat-tile" key={index}>
          <div className="stat-label">{item.label}</div>
          <div className="stat-value">
            {String(item.value)}
            {item.unit ? <span className="stat-unit"> {item.unit}</span> : null}
          </div>
          {item.delta === undefined ? null : <Delta delta={item.delta} />}
          {item.hint ? <div className="stat-hint">{item.hint}</div> : null}
        </div>
      ))}
    </div>
  );
}
