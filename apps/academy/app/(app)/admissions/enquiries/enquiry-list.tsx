import { Card, CardContent } from '@/components/ui/card';

export type EnquiryRow = {
  id: string;
  enquiry_no: string | null;
  child_name: string;
  phone_e164: string;
  source: string;
  status: string;
};

export function EnquiryList({ enquiries }: { enquiries: EnquiryRow[] }) {
  if (enquiries.length === 0) {
    return <p className="text-sm text-muted-foreground">No enquiries yet.</p>;
  }

  return (
    <div className="space-y-2">
      {enquiries.map((e) => (
        <Card key={e.id} data-testid={`enquiry-row-${e.enquiry_no}`}>
          <CardContent className="flex items-center justify-between p-4">
            <div>
              <p className="font-medium">
                {e.child_name} <span className="text-muted-foreground">({e.enquiry_no})</span>
              </p>
              <p className="text-sm text-muted-foreground">
                {e.phone_e164} · {e.source.replace(/_/g, ' ')} · {e.status}
              </p>
            </div>
          </CardContent>
        </Card>
      ))}
    </div>
  );
}
