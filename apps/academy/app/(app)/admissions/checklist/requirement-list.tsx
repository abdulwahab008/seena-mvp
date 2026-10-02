export type RequirementRow = {
  id: string;
  doc_type: string;
  min_class_ordinal: number;
  max_class_ordinal: number;
  is_mandatory: boolean;
  min_count: number;
};

export function RequirementList({ requirements, classLabel }: { requirements: RequirementRow[]; classLabel: (ordinal: number) => string }) {
  if (requirements.length === 0) {
    return <p className="text-sm text-muted-foreground">No document requirements configured yet.</p>;
  }

  return (
    <div className="rounded-lg border">
      <table className="w-full text-sm">
        <thead>
          <tr className="border-b text-left text-muted-foreground">
            <th className="p-2">Document</th>
            <th className="p-2">Class range</th>
            <th className="p-2">Required</th>
            <th className="p-2">Count</th>
          </tr>
        </thead>
        <tbody>
          {requirements.map((r) => (
            <tr key={r.id} data-testid={`requirement-row-${r.doc_type}`} className="border-b last:border-0">
              <td className="p-2">{r.doc_type.replace(/_/g, ' ')}</td>
              <td className="p-2">
                {classLabel(r.min_class_ordinal)} – {classLabel(r.max_class_ordinal)}
              </td>
              <td className="p-2 text-muted-foreground">{r.is_mandatory ? 'Mandatory' : 'Optional'}</td>
              <td className="p-2 text-muted-foreground">{r.min_count}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
