import { createElement, type ReactElement } from 'react';
import { renderToBuffer, type DocumentProps } from '@react-pdf/renderer';
import { ExamDocument, type ExamPdfProps } from './exam-pdf';

export async function renderExamPdf(props: ExamPdfProps): Promise<Buffer> {
  const element = createElement(ExamDocument, props) as unknown as ReactElement<DocumentProps>;
  return renderToBuffer(element);
}
