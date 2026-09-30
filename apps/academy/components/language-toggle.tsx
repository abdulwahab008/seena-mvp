'use client';

import { useTransition } from 'react';
import { setLanguage } from '@/lib/i18n/actions';
import { t, type Lang } from '@/lib/i18n/messages';

export function LanguageToggle({ lang }: { lang: Lang }) {
  const [pending, startTransition] = useTransition();
  const target: Lang = lang === 'ur' ? 'en' : 'ur';
  return (
    <button
      type="button"
      disabled={pending}
      aria-label={t(lang, 'lang.switchLabel')}
      data-testid="language-toggle"
      className="rounded-full border px-3 py-1 text-sm hover:bg-muted"
      onClick={() => startTransition(async () => void (await setLanguage(target)))}
    >
      {t(lang, 'lang.switchTo')}
    </button>
  );
}
