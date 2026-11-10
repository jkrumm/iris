import type { ListSpec } from "../spec";

export function ListView({ spec }: { spec: ListSpec }) {
  const Tag = spec.ordered ? "ol" : "ul";
  return (
    <Tag className="list">
      {spec.items.map((item, index) => (
        <li key={index}>
          <div>{item.text}</div>
          {item.detail ? <div className="list-detail">{item.detail}</div> : null}
        </li>
      ))}
    </Tag>
  );
}
