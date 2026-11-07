import type { DigestMessage, DigestTransport, SendResult } from '@/lib/digests/transport';
import { sendEmail } from '@/lib/email/send';
import { escapeHtml } from '@/lib/challan/html';

export class ResendEmailTransport implements DigestTransport {
  readonly name = 'resend-email';
  async send(message: DigestMessage): Promise<SendResult> {
    if (!message.toEmail) return { ok: false, transient: false, errorCode: 'NO_EMAIL', errorText: 'No email address' };
    const html = `<p>${escapeHtml(message.body).replace(/\n/g, '<br>')}</p>`;
    const r = await sendEmail({ to: message.toEmail, subject: message.title || 'Message from school', html, text: message.body });
    return r.ok ? { ok: true, providerMsgId: r.id } : { ok: false, transient: r.reason !== 'not_configured', errorCode: r.reason, errorText: r.detail };
  }
}
