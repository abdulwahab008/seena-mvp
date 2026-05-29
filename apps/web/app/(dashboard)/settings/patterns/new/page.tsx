import { requireSession } from '@/lib/auth';
import { getPattern, type PatternSpec } from '@seena/shared/patterns';
import { PatternBuilder } from '@/components/pattern-builder/pattern-builder';

export default async function NewPatternPage({
  searchParams,
}: {
  searchParams: Promise<{ from?: string }>;
}) {
  await requireSession();
  const sp = await searchParams;
  let initial: PatternSpec | undefined;
  if (sp.from) {
    const source = getPattern(sp.from);
    if (source) {
      initial = {
        ...source,
        id: '',
        name: `${source.name} (copy)`,
      };
    }
  }
  return (
    <div className="mx-auto max-w-3xl">
      <PatternBuilder mode="create" initial={initial} />
    </div>
  );
}
