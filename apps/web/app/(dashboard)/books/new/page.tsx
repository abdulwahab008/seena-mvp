import { BookUploader } from '@/components/book-uploader/book-uploader';

export default function NewBookPage() {
  return (
    <div className="max-w-2xl space-y-6">
      <h1 className="text-2xl font-semibold">Upload a book</h1>
      <p className="text-sm text-muted-foreground">
        Upload a PDF you have rights to use. By uploading, you confirm you have permission to use
        this content for exam generation. Your books are private to your organization.
      </p>
      <BookUploader />
    </div>
  );
}
