import { Metadata } from 'next';
import { getTemplates, getPlaceholders } from './actions';
import { TemplateDesk } from './template-desk';

export const metadata: Metadata = {
  title: 'Message Template Library | Communication | Seena Academy',
};

type SearchParams = { category?: string; audience?: string; search?: string };

export default async function CommunicationTemplatesPage({
  searchParams,
}: {
  searchParams: Promise<SearchParams>;
}) {
  const params = await searchParams;

  const [templates, placeholders] = await Promise.all([
    getTemplates({
      category: params.category,
      audience: params.audience,
      search: params.search,
    }),
    getPlaceholders(),
  ]);

  return (
    <div className="space-y-6">
      <TemplateDesk initialTemplates={templates} placeholders={placeholders} />
    </div>
  );
}
