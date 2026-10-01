import { chartGeometry, type SubjectTrend } from '@/lib/exams/trend';

/**
 * FR-J06. One subject's trend: the child's points and the section average on
 * the same 0-100 axis. Pure SVG, rendered on the server, so the results-day
 * portal ships no chart library and no client JavaScript for it.
 *
 * The section line is simply not drawn when the average was suppressed, and
 * the note says why in words — an empty axis with no explanation reads as a bug.
 */
export function SubjectTrendChart({ trend, ownLabel = 'Your child' }: { trend: SubjectTrend; ownLabel?: string }) {
  const g = chartGeometry(trend.points);
  const own = g.own.map((p) => `${p.x},${p.y}`).join(' ');
  return (
    <figure className="space-y-2" data-testid={`trend-${trend.subjectName}`}>
      <figcaption className="flex items-baseline justify-between gap-2 text-sm">
        <span className="font-medium">{trend.subjectName}</span>
        <span className="text-xs text-muted-foreground" data-testid={`trend-direction-${trend.subjectName}`}>
          {trend.direction === 'improving' && 'Improving'}
          {trend.direction === 'slipping' && 'Slipping'}
          {trend.direction === 'steady' && 'Steady'}
          {trend.direction === 'single' && 'One term so far'}
        </span>
      </figcaption>
      <svg
        viewBox={`0 0 ${g.width} ${g.height}`}
        role="img"
        aria-label={`${trend.subjectName} percentage by term`}
        className="h-auto w-full max-w-md"
      >
        {g.yTicks.map((t) => (
          <g key={t.label}>
            <line x1={34} x2={g.width - 12} y1={t.y} y2={t.y} stroke="currentColor" strokeOpacity={0.12} />
            <text x={30} y={t.y + 3} textAnchor="end" fontSize={9} fill="currentColor" fillOpacity={0.6}>
              {t.label}
            </text>
          </g>
        ))}
        {g.avgRuns.map((run, i) => (
          <polyline
            key={i}
            points={run.map((p) => `${p.x},${p.y}`).join(' ')}
            fill="none"
            stroke="currentColor"
            strokeOpacity={0.45}
            strokeWidth={1.5}
            strokeDasharray="4 3"
            data-testid={`trend-avg-line-${trend.subjectName}`}
          />
        ))}
        {g.avgRuns.flat().map((p, i) => (
          <circle key={i} cx={p.x} cy={p.y} r={2.5} fill="currentColor" fillOpacity={0.45} />
        ))}
        {g.own.length > 1 && <polyline points={own} fill="none" stroke="hsl(var(--primary))" strokeWidth={2} />}
        {g.own.map((p, i) => (
          <g key={i}>
            <circle cx={p.x} cy={p.y} r={3.5} fill="hsl(var(--primary))" data-testid={`trend-point-${trend.subjectName}`} />
            <text x={p.x} y={g.height - 10} textAnchor="middle" fontSize={9} fill="currentColor" fillOpacity={0.7}>
              {p.label}
            </text>
          </g>
        ))}
      </svg>
      <table className="w-full text-xs">
        <thead className="text-left text-muted-foreground">
          <tr>
            <th className="py-0.5 font-normal">Term</th>
            <th className="py-0.5 font-normal">{ownLabel}</th>
            <th className="py-0.5 font-normal">Section average</th>
          </tr>
        </thead>
        <tbody>
          {trend.points.map((p) => (
            <tr key={p.termId} data-testid={`trend-row-${trend.subjectName}-${p.termName}`}>
              <td className="py-0.5">{p.termName}</td>
              <td className="py-0.5">{p.pct.toFixed(0)}%</td>
              <td className="py-0.5">{p.sectionAvg === null ? '—' : `${p.sectionAvg.toFixed(0)}%`}</td>
            </tr>
          ))}
        </tbody>
      </table>
      {trend.suppressedNote && (
        <p className="text-xs text-muted-foreground" data-testid={`trend-suppressed-${trend.subjectName}`}>
          Section average: {trend.suppressedNote}.
        </p>
      )}
    </figure>
  );
}
