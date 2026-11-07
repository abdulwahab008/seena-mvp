import { TakeQuiz } from './take-quiz';

export default async function TakeQuizPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  return <TakeQuiz quizId={id} />;
}
