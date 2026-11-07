import { MergeForm } from './merge-form';

export default function MergeStudentsPage() {
  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-2xl font-semibold">Merge duplicate students</h1>
        <p className="text-sm text-muted-foreground">
          When the same child was entered twice, move everything from the duplicate onto the record you keep: guardians, fees, attendance, results and the rest. Check the preview first. The duplicate goes to the recycle bin. If both records have something that can exist only once, such as an enrolment in the same session, nothing moves until you remove one.
        </p>
      </div>
      <MergeForm />
    </div>
  );
}
