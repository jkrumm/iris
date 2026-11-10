import type { Scheme } from "../payload";
import type { ShowSpec } from "../spec";
import { CalloutView } from "./Callout";
import { ChartView } from "./Chart";
import { ListView } from "./List";
import { StatView } from "./Stat";
import { TableView } from "./Table";

function Body({ spec, scheme }: { spec: ShowSpec; scheme: Scheme }) {
  switch (spec.type) {
    case "table":
      return <TableView spec={spec} />;
    case "chart":
      return <ChartView spec={spec} scheme={scheme} />;
    case "stat":
      return <StatView spec={spec} />;
    case "list":
      return <ListView spec={spec} />;
    case "callout":
      return <CalloutView spec={spec} />;
  }
}

export function ShowArtifact({ spec, scheme }: { spec: ShowSpec; scheme: Scheme }) {
  const title = spec.title;
  return (
    <section className={`card show-${spec.type}`}>
      {title ? <h2 className="card-title">{title}</h2> : null}
      <Body spec={spec} scheme={scheme} />
    </section>
  );
}
