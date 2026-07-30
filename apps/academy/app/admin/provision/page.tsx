import { Card, CardContent, CardHeader, CardTitle, CardDescription } from '@/components/ui/card';
import { ProvisionForm } from './provision-form';

export default function ProvisionPage() {
  return (
    <div className="flex min-h-screen items-center justify-center p-4">
      <Card className="w-full max-w-md">
        <CardHeader>
          <CardTitle>Provision a tenant</CardTitle>
          <CardDescription>FR-A01 — creates a tenant, its first campus, current academic session and an owner invitation.</CardDescription>
        </CardHeader>
        <CardContent>
          <ProvisionForm />
        </CardContent>
      </Card>
    </div>
  );
}
