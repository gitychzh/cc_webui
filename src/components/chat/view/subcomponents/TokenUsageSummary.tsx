import { ActivityIcon } from 'lucide-react';
import Tooltip from '../../../../shared/view/ui/Tooltip';

type TokenUsageSummaryProps = {
  usage: Record<string, unknown> | null;
  model?: string;
};

const readUsageNumber = (value: unknown) => {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
};

const formatK = (value: number) => {
  if (!Number.isFinite(value) || value <= 0) return '0k';
  return value >= 1_000_000
    ? `${(value / 1_000_000).toFixed(value >= 10_000_000 ? 0 : 1)}M`
    : `${(value / 1_000).toFixed(value >= 100_000 ? 0 : 1)}k`;
};

const MODEL_LABELS: Record<string, string> = {
  'claude-opus-4-7-20250514': 'Opus 4.7',
  'claude-sonnet-4-6-20250514': 'Sonnet 4.6',
  'claude-haiku-4-5-20251001': 'Haiku 4.5',
  'default': 'Opus 4.7',
  'sonnet': 'Sonnet 4.6',
  'sonnet[1m]': 'Sonnet 4.6 (1M)',
  'haiku': 'Haiku 4.5',
  'opus': 'Opus 4.7',
};

const resolveModelLabel = (rawModel: string | null | undefined): string => {
  if (!rawModel) return '';
  return MODEL_LABELS[rawModel] || rawModel.replace(/^claude-/, '');
};

export default function TokenUsageSummary({ usage, model }: TokenUsageSummaryProps) {
  const breakdown = usage?.breakdown && typeof usage.breakdown === 'object'
    ? usage.breakdown as Record<string, unknown>
    : null;
  const inputTokens = readUsageNumber(usage?.inputTokens ?? breakdown?.input);
  const outputTokens = readUsageNumber(usage?.outputTokens ?? breakdown?.output);
  const cacheCreationTokens = readUsageNumber(usage?.cacheCreationTokens ?? breakdown?.cacheCreation);
  const cacheReadTokens = readUsageNumber(usage?.cacheReadTokens ?? breakdown?.cacheRead);
  const usedTokens = readUsageNumber(usage?.used) || inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens;
  const totalTokens = readUsageNumber(usage?.total) || 0;
  const budgetModel = typeof usage?.model === 'string' ? usage.model : null;
  const displayModel = resolveModelLabel(budgetModel || model);
  const pct = totalTokens > 0 ? Math.min(usedTokens / totalTokens * 100, 100) : 0;

  if (usedTokens <= 0) return null;

  const barColor = pct < 50
    ? 'bg-emerald-500'
    : pct < 80
      ? 'bg-amber-500'
      : 'bg-red-500';

  const borderColor = pct < 50
    ? 'border-emerald-500/30'
    : pct < 80
      ? 'border-amber-500/30'
      : 'border-red-500/30';

  const detailContent = (
    <div className="flex flex-col gap-0.5 text-[11px]">
      {displayModel && <div className="font-semibold">{displayModel}</div>}
      <div>Input: {inputTokens.toLocaleString()} ({formatK(inputTokens)})</div>
      {cacheCreationTokens > 0 && <div>Cache creation: {cacheCreationTokens.toLocaleString()} ({formatK(cacheCreationTokens)})</div>}
      {cacheReadTokens > 0 && <div>Cache read: {cacheReadTokens.toLocaleString()} ({formatK(cacheReadTokens)})</div>}
      <div>Output: {outputTokens.toLocaleString()} ({formatK(outputTokens)})</div>
      <div>Total: {usedTokens.toLocaleString()} ({formatK(usedTokens)}) / {totalTokens.toLocaleString()} ({formatK(totalTokens)})</div>
      <div>Context: {pct.toFixed(1)}% used</div>
    </div>
  );

  return (
    <Tooltip content={detailContent} position="top" delay={200}>
      <div
        className={`inline-flex h-9 items-center gap-1.5 rounded-lg border ${borderColor} bg-background/70 px-2 text-xs text-muted-foreground shadow-sm transition-all cursor-pointer sm:gap-2 sm:px-2.5`}
      >
        <span className="grid h-5 w-5 place-items-center rounded-md bg-primary/10 text-primary">
          <ActivityIcon className="h-3.5 w-3.5" />
        </span>

        {/* Mini progress bar */}
        <div className="flex items-center gap-1.5">
          <div className="h-2.5 w-20 rounded-full bg-muted overflow-hidden">
            <div
              className={`h-full rounded-full transition-all duration-500 ${barColor}`}
              style={{ width: `${pct}%` }}
            />
          </div>
          <span className="font-medium tabular-nums text-foreground">{pct.toFixed(1)}%</span>
        </div>

        {/* Model badge */}
        {displayModel && (
          <span className="hidden text-[10px] font-medium text-muted-foreground/80 sm:inline">{displayModel}</span>
        )}
      </div>
    </Tooltip>
  );
}