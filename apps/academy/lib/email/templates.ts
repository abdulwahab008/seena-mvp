/**
 * Branded transactional email bodies.
 *
 * Inline styles only, tables for layout, no external CSS or webfonts — that is
 * what mail clients actually render. Every template ships a plain-text twin;
 * an HTML-only message scores as spam and is unreadable in text-mode clients.
 */

const BRAND = '#3730a3';
const INK = '#111827';
const MUTED = '#6b7280';
const BORDER = '#e5e7eb';

function escapeHtml(value: string) {
  return value
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function layout({
  heading,
  body,
  cta,
  footnote,
  schoolName,
}: {
  heading: string;
  body: string;
  cta?: { label: string; url: string };
  footnote?: string;
  schoolName: string;
}) {
  const safeSchool = escapeHtml(schoolName);
  return `<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${escapeHtml(heading)}</title></head>
<body style="margin:0;padding:0;background:#f4f5f7;">
  <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f4f5f7;padding:32px 12px;">
    <tr><td align="center">
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:520px;background:#ffffff;border:1px solid ${BORDER};border-radius:12px;overflow:hidden;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif;">
        <tr><td style="background:${BRAND};padding:20px 28px;">
          <span style="color:#ffffff;font-size:16px;font-weight:600;letter-spacing:-0.01em;">${safeSchool}</span>
          <span style="color:#c7d2fe;font-size:13px;display:block;margin-top:2px;">Seena Academy</span>
        </td></tr>
        <tr><td style="padding:28px;">
          <h1 style="margin:0 0 12px;font-size:19px;line-height:1.35;color:${INK};font-weight:600;">${escapeHtml(heading)}</h1>
          <div style="margin:0;font-size:15px;line-height:1.6;color:#374151;">${body}</div>
          ${
            cta
              ? `<table role="presentation" cellpadding="0" cellspacing="0" style="margin:24px 0 8px;"><tr><td style="border-radius:8px;background:${BRAND};">
                  <a href="${cta.url}" style="display:inline-block;padding:12px 22px;font-size:15px;font-weight:600;color:#ffffff;text-decoration:none;border-radius:8px;">${escapeHtml(cta.label)}</a>
                </td></tr></table>
                <p style="margin:12px 0 0;font-size:13px;line-height:1.5;color:${MUTED};word-break:break-all;">Or paste this link into your browser:<br><a href="${cta.url}" style="color:${BRAND};">${cta.url}</a></p>`
              : ''
          }
          ${footnote ? `<p style="margin:22px 0 0;padding-top:16px;border-top:1px solid ${BORDER};font-size:13px;line-height:1.55;color:${MUTED};">${footnote}</p>` : ''}
        </td></tr>
        <tr><td style="padding:16px 28px;background:#fafafa;border-top:1px solid ${BORDER};">
          <p style="margin:0;font-size:12px;line-height:1.5;color:${MUTED};">This is an automated message from ${safeSchool}. Please do not reply to it.</p>
        </td></tr>
      </table>
    </td></tr>
  </table>
</body>
</html>`;
}

export function passwordResetEmail({ url, schoolName }: { url: string; schoolName: string }) {
  return {
    subject: `Reset your ${schoolName} password`,
    html: layout({
      schoolName,
      heading: 'Reset your password',
      body: `<p style="margin:0;">We received a request to reset the password for this account. Choose a new one using the button below.</p>`,
      cta: { label: 'Choose a new password', url },
      footnote:
        'This link expires in 1 hour and can be used once. If you did not request a password reset, you can ignore this email — your password will not change.',
    }),
    text: [
      'Reset your password',
      '',
      `We received a request to reset the password for your ${schoolName} account.`,
      '',
      'Open this link to choose a new one:',
      url,
      '',
      'The link expires in 1 hour and can be used once.',
      'If you did not request a password reset, ignore this email — your password will not change.',
    ].join('\n'),
  };
}

export function emailVerificationEmail({ url, schoolName }: { url: string; schoolName: string }) {
  return {
    subject: `Confirm your email for ${schoolName}`,
    html: layout({
      schoolName,
      heading: 'Confirm your email address',
      body: `<p style="margin:0;">Confirm this address to finish setting up your ${escapeHtml(schoolName)} account.</p>`,
      cta: { label: 'Confirm email address', url },
      footnote:
        'If you did not create this account, you can safely ignore this email and nothing further will happen.',
    }),
    text: [
      'Confirm your email address',
      '',
      `Confirm this address to finish setting up your ${schoolName} account:`,
      url,
      '',
      'If you did not create this account, ignore this email.',
    ].join('\n'),
  };
}
