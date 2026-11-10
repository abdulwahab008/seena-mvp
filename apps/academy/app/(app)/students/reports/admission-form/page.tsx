import { supabaseServer } from '@/lib/supabase/server';
import { PrintButton } from '@/components/print-button';

export const dynamic = 'force-dynamic';

const STUDENT = ['Student name', 'Date of birth', 'Gender', 'B-Form number', 'Religion', 'Nationality', 'Blood group', 'Class applied for', 'Previous school'];
const PARENT = ['Father name', 'Father CNIC', 'Father occupation', 'Mother name', 'Mobile number', 'WhatsApp number', 'Email', 'Home address'];

function Fields({ title, fields }: { title: string; fields: string[] }) {
  return (
    <section className="space-y-3">
      <h2 className="border-b pb-1 text-sm font-semibold uppercase tracking-wide text-muted-foreground">{title}</h2>
      <div className="grid gap-x-8 gap-y-4 sm:grid-cols-2 print:grid-cols-2">
        {fields.map((f) => (
          <div key={f} className="flex items-end gap-2 text-sm">
            <span className="shrink-0">{f}</span>
            <span className="h-5 flex-1 border-b border-dashed" />
          </div>
        ))}
      </div>
    </section>
  );
}

export default async function AdmissionFormPage() {
  const supabase = await supabaseServer();
  const { data: tenant } = await supabase.from('tenant').select('name').limit(1).maybeSingle();

  return (
    <div className="mx-auto max-w-3xl space-y-8">
      <div className="flex justify-end print:hidden">
        <PrintButton />
      </div>
      <header className="flex items-start justify-between gap-4">
        <div>
          <p className="text-xl font-semibold">{tenant?.name}</p>
          <h1 className="text-2xl font-semibold">Admission form</h1>
        </div>
        <div className="flex h-32 w-28 items-center justify-center border text-xs text-muted-foreground">Photo</div>
      </header>
      <Fields title="Student" fields={STUDENT} />
      <Fields title="Parent or guardian" fields={PARENT} />
      <section className="space-y-6 text-sm">
        <p>I confirm the information above is correct and agree to follow the rules of the school.</p>
        <div className="grid grid-cols-2 gap-8 pt-8">
          <span className="border-t pt-1">Parent signature</span>
          <span className="border-t pt-1">Principal signature</span>
        </div>
      </section>
    </div>
  );
}
