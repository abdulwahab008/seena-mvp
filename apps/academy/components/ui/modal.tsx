'use client';

import * as React from 'react';
import { X } from 'lucide-react';
import { cn } from '@/lib/utils';
import { Button } from '@/components/ui/button';

/**
 * Built on the native <dialog> element rather than a portal + overlay library:
 * showModal() gives focus trapping, ESC-to-close, inert background and the
 * top-layer stacking for free, which is most of what a dialog dependency sells.
 */
export function Modal({
  open,
  onClose,
  title,
  description,
  children,
  footer,
  size = 'md',
  className,
  hideHeader = false,
  rawChildren = false,
}: {
  open: boolean;
  onClose: () => void;
  title: string;
  description?: React.ReactNode;
  children?: React.ReactNode;
  footer?: React.ReactNode;
  size?: 'sm' | 'md' | 'lg' | 'xl' | '2xl';
  className?: string;
  hideHeader?: boolean;
  rawChildren?: boolean;
}) {
  const ref = React.useRef<HTMLDialogElement>(null);

  React.useEffect(() => {
    const el = ref.current;
    if (!el) return;
    if (open && !el.open) el.showModal();
    if (!open && el.open) el.close();
  }, [open]);

  // ESC fires the dialog's own `cancel`; keep React state in step with it.
  React.useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const handleCancel = (e: Event) => {
      e.preventDefault();
      onClose();
    };
    el.addEventListener('cancel', handleCancel);
    return () => el.removeEventListener('cancel', handleCancel);
  }, [onClose]);

  const width = {
    sm: 'max-w-sm',
    md: 'max-w-lg',
    lg: 'max-w-3xl',
    xl: 'max-w-5xl',
    '2xl': 'max-w-6xl',
  }[size];

  return (
    <dialog
      ref={ref}
      className={cn(
        'w-[calc(100vw-2rem)] rounded-xl border bg-card p-0 text-card-foreground shadow-2xl backdrop:bg-transparent relative',
        width,
        className,
      )}
      // Clicking the backdrop lands on the dialog element itself, never a child.
      onClick={(e) => {
        if (e.target === ref.current) onClose();
      }}
    >
      {!hideHeader && (
        <div className="flex items-start justify-between gap-4 border-b px-5 py-4">
          <div className="min-w-0 space-y-1">
            <h2 className="text-base font-semibold leading-none tracking-tight">{title}</h2>
            {description ? <p className="text-sm text-muted-foreground">{description}</p> : null}
          </div>
          <Button
            type="button"
            variant="ghost"
            size="icon"
            className="-mr-2 -mt-2 h-8 w-8 shrink-0"
            onClick={onClose}
            aria-label="Close"
          >
            <X className="h-4 w-4" />
          </Button>
        </div>
      )}

      {hideHeader && (
        <Button
          type="button"
          variant="ghost"
          size="icon"
          className="absolute right-3.5 top-3.5 z-20 h-8 w-8 rounded-full bg-background/80 hover:bg-background shadow-xs text-muted-foreground hover:text-foreground"
          onClick={onClose}
          aria-label="Close"
        >
          <X className="h-4 w-4" />
        </Button>
      )}

      {children ? (
        rawChildren ? (
          <div className="overflow-hidden">{children}</div>
        ) : (
          <div className="max-h-[65vh] overflow-y-auto px-5 py-4">{children}</div>
        )
      ) : null}

      {footer ? (
        <div className="flex flex-wrap items-center justify-end gap-2 border-t bg-muted/30 px-5 py-3">
          {footer}
        </div>
      ) : null}
    </dialog>
  );
}

/**
 * Confirmation for destructive actions. `confirmWord` turns the button into a
 * type-to-confirm gate for things that cannot be undone.
 */
export function ConfirmDialog({
  open,
  onClose,
  onConfirm,
  title,
  description,
  confirmLabel = 'Confirm',
  cancelLabel = 'Cancel',
  destructive = false,
  pending = false,
  confirmWord,
  confirmTestId = 'confirm-action',
}: {
  open: boolean;
  onClose: () => void;
  onConfirm: () => void;
  title: string;
  description?: React.ReactNode;
  confirmLabel?: string;
  cancelLabel?: string;
  destructive?: boolean;
  pending?: boolean;
  confirmWord?: string;
  confirmTestId?: string;
}) {
  const [typed, setTyped] = React.useState('');
  React.useEffect(() => {
    if (open) setTyped('');
  }, [open]);

  const blocked = Boolean(confirmWord) && typed.trim() !== confirmWord;

  return (
    <Modal
      open={open}
      onClose={onClose}
      title={title}
      description={description}
      size="sm"
      footer={
        <>
          <Button type="button" variant="outline" onClick={onClose} disabled={pending}>
            {cancelLabel}
          </Button>
          <Button
            type="button"
            variant={destructive ? 'destructive' : 'default'}
            onClick={onConfirm}
            disabled={pending || blocked}
            data-testid={confirmTestId}
          >
            {pending ? 'Working…' : confirmLabel}
          </Button>
        </>
      }
    >
      {confirmWord ? (
        <label className="block space-y-2 text-sm">
          <span className="text-muted-foreground">
            Type <span className="font-mono font-medium text-foreground">{confirmWord}</span> to confirm.
          </span>
          <input
            value={typed}
            onChange={(e) => setTyped(e.target.value)}
            className="h-10 w-full rounded-md border border-input bg-background px-3 text-sm focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
            autoComplete="off"
            data-testid="confirm-word-input"
          />
        </label>
      ) : null}
    </Modal>
  );
}
