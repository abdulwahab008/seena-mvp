import { LinkChildForm } from './link-child-form';

export default function LinkChildPage() {
  return (
    <div className="space-y-4">
      <div>
        <h2 className="text-lg font-semibold">Add another child</h2>
        <p className="text-sm text-muted-foreground">
          Activating your account linked only one child. Add a sibling with their GR number and the last 6 digits of your CNIC.
        </p>
      </div>
      <LinkChildForm />
    </div>
  );
}
