import { messages } from "../messages";
import type { Cell, TableSpec } from "../spec";

const display = (cell: Cell): string => {
  if (cell === null) return messages.emptyCell;
  if (typeof cell === "boolean") return cell ? messages.yes : messages.no;
  return String(cell);
};

export function TableView({ spec }: { spec: TableSpec }) {
  const numeric = spec.columns.map((_, index) =>
    spec.rows.every((row) => row[index] === null || typeof row[index] === "number"),
  );
  return (
    <table className="table">
      <thead>
        <tr>
          {spec.columns.map((column, index) => (
            <th key={index} className={numeric[index] ? "num" : undefined}>
              {column}
            </th>
          ))}
        </tr>
      </thead>
      <tbody>
        {spec.rows.map((row, rowIndex) => (
          <tr key={rowIndex}>
            {row.map((cell, index) => (
              <td
                key={index}
                className={[numeric[index] ? "num" : "", cell === null ? "empty" : ""]
                  .filter(Boolean)
                  .join(" ")}
              >
                {display(cell)}
              </td>
            ))}
          </tr>
        ))}
      </tbody>
    </table>
  );
}
