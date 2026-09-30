'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { createTicketAction } from './actions';
import { Button } from '@/components/ui/button';
import { Input } from '@/components/ui/input';
import { Label } from '@/components/ui/label';
import { Textarea } from '@/components/ui/textarea';
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from '@/components/ui/select';
import { Modal } from '@/components/ui/modal';
import { AlertCircle, Plus } from 'lucide-react';

interface StudentOption {
  id: string;
  name_en: string;
  gr_number: string;
}

interface NewTicketDialogProps {
  campusId: string;
  students: StudentOption[];
}

export function NewTicketDialog({ campusId, students }: NewTicketDialogProps) {
  const router = useRouter();
  const [open, setOpen] = useState(false);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const [category, setCategory] = useState<string>('transport');
  const [studentId, setStudentId] = useState<string>(students[0]?.id || '');
  const [subject, setSubject] = useState('');
  const [description, setDescription] = useState('');

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault();
    setLoading(true);
    setError(null);

    const formData = new FormData();
    formData.append('campus_id', campusId);
    formData.append('category', category);
    formData.append('student_id', studentId);
    formData.append('subject', subject);
    formData.append('description', description);

    const res = await createTicketAction(formData);
    setLoading(false);

    if (res.error) {
      setError(res.error);
    } else {
      setOpen(false);
      setSubject('');
      setDescription('');
      router.refresh();
    }
  }

  return (
    <>
      <Button className="gap-2" onClick={() => setOpen(true)}>
        <Plus className="h-4 w-4" />
        Raise Complaint / Query
      </Button>

      <Modal
        open={open}
        onClose={() => setOpen(false)}
        title="Raise Complaint or Query"
        description="Submit an official ticket to the school office. You will receive a gap-free reference number and track resolution progress."
        size="md"
        footer={
          <div className="flex justify-end gap-2">
            <Button type="button" variant="outline" onClick={() => setOpen(false)} disabled={loading}>
              Cancel
            </Button>
            <Button type="submit" form="new-ticket-form" disabled={loading}>
              {loading ? 'Submitting...' : 'Submit Ticket'}
            </Button>
          </div>
        }
      >
        <form id="new-ticket-form" onSubmit={handleSubmit} className="space-y-4">
          {error && (
            <div className="flex items-center gap-2 rounded-md bg-destructive/15 p-3 text-sm text-destructive">
              <AlertCircle className="h-4 w-4 shrink-0" />
              <span>{error}</span>
            </div>
          )}

          <div className="space-y-2">
            <Label htmlFor="category">Category</Label>
            <Select value={category} onValueChange={setCategory}>
              <SelectTrigger id="category">
                <SelectValue placeholder="Select category" />
              </SelectTrigger>
              <SelectContent>
                <SelectItem value="transport">Transport / School Van</SelectItem>
                <SelectItem value="fee">Fees & Challans</SelectItem>
                <SelectItem value="teaching">Academics & Teaching</SelectItem>
                <SelectItem value="discipline">Discipline & Conduct</SelectItem>
                <SelectItem value="other">Other Query</SelectItem>
              </SelectContent>
            </Select>
          </div>

          {students.length > 0 && (
            <div className="space-y-2">
              <Label htmlFor="student">Linked Child (Optional)</Label>
              <Select value={studentId} onValueChange={setStudentId}>
                <SelectTrigger id="student">
                  <SelectValue placeholder="Select child" />
                </SelectTrigger>
                <SelectContent>
                  {students.map((s) => (
                    <SelectItem key={s.id} value={s.id}>
                      {s.name_en} ({s.gr_number})
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          )}

          <div className="space-y-2">
            <Label htmlFor="subject">Subject</Label>
            <Input
              id="subject"
              placeholder="e.g. Route 4 van arrives late every morning"
              value={subject}
              onChange={(e) => setSubject(e.target.value)}
              required
              minLength={3}
            />
          </div>

          <div className="space-y-2">
            <Label htmlFor="description">Message / Details</Label>
            <Textarea
              id="description"
              placeholder="Describe your issue or complaint in detail..."
              rows={4}
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              required
            />
          </div>
        </form>
      </Modal>
    </>
  );
}
